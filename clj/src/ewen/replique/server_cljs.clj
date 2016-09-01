(ns ewen.replique.server-cljs
  (:require [ewen.replique.server :refer [with-tooling-response]
             :as server]
            [clojure.core.server :refer [start-server *session*]]
            [clojure.java.io :as io :refer [file]]
            [cljs.repl.browser]
            [cljs.closure :as closure]
            [cljs.env :as cljs-env]
            [cljs.analyzer :as ana]
            [cljs.analyzer.api :as ana-api]
            [cljs.compiler :as comp]
            [cljs.util :as util]
            [cljs.repl]
            [clojure.string :as string]
            [cljs.js-deps :as deps]
            [clojure.tools.reader :as reader]
            [cljs.closure :as cljsc]
            [ewen.replique.cljs]
            [ewen.replique.sourcemap]
            [ewen.replique.compliment.context :as context]
            [ewen.replique.compliment.sources.local-bindings
             :refer [bindings-from-context]]
            [clojure.data.json :as json]
            [cljs.tagged-literals :as tags]
            [ewen.replique.compliment.core :as compliment]
            [clojure.spec :as s])
  (:import [java.io File BufferedReader InputStreamReader]
           [java.net URL ServerSocket]
           [java.util.concurrent SynchronousQueue Executors ThreadFactory
            RejectedExecutionException]
           [java.net SocketException]
           [clojure.lang IExceptionInfo]
           [java.util.concurrent.locks ReentrantLock]))

(defonce compiler-env (ref nil))
(defonce repl-env (ref nil))
(defonce cljs-outs (atom #{}))
(def ^:dynamic *stopped-eval-executor?* false)

(def default-repl-requires '[[cljs.repl :refer-macros [source doc find-doc apropos dir pst]]
                             [cljs.pprint :refer [pprint] :refer-macros [pp]]])
(def env {:context :expr :locals {}})

(s/def ::cljs-env-type #{:browser :webapp})
(s/def ::output-to string?)
(s/def ::main string?)
(s/def ::compiler-env (s/keys :req-un [::output-to] :opt-un [::main]))
(s/def ::port number?)
(s/def ::repl-env (s/keys :req-un [::port]))
(s/def ::cljs-env (s/keys :req-un [::cljs-env-type ::compiler-env ::repl-env]))

(comment
  (s/conform ::cljs-env {:cljs-env-type :browser
                         :compiler-env {:output-to "out/main.js"}
                         :repl-env {:port 9001}})
  (s/explain-str ::cljs-env {:cljs-env-type :browser
                             :compiler-env {:output-to "out/main.js"}
                             :repl-env2 {:port 9001}})
  (s/explain-str ::cljs-env [])
  )

(defmacro ^:private with-lock
  [lock-expr & body]
  `(let [lockee# ~(with-meta lock-expr
                    {:tag 'java.util.concurrent.locks.ReentrantLock})]
     (.lock lockee#)
     (try
       ~@body
       (finally
         (.unlock lockee#)))))

(defn make-eval-executor-thread-factory [repl-env]
  (reify ThreadFactory
    (newThread [this runnable]
      (binding [cljs.repl.browser/browser-state (:browser-state repl-env)
                cljs.repl.browser/ordering (:ordering repl-env)
                cljs.repl.browser/es (:es repl-env)
                cljs.repl.server/state (:server-state repl-env)]
        (Thread. ((ns-resolve 'clojure.core 'binding-conveyor-fn)
                  (fn [] (.run runnable))))))))

(defn make-eval-executor [repl-env]
  (-> (make-eval-executor-thread-factory repl-env)
      (Executors/newSingleThreadExecutor)))

(defn make-eval-task [js]
  (reify Callable
    (call [this]
      (if *stopped-eval-executor?*
        {:status :error
         :value "Connection broken"}
        (try
          (cljs.repl.browser/browser-eval js)
          ;; If the repl-env is shutdown
          (catch InterruptedException e
            {:status :error
             :value "Connection broken"})
          ;; Other errors, socket closed by the client ...
          (catch SocketException e
            (doseq [[out lock] @cljs-outs]
              (binding [*out* out]
                (prn e)))
            {:status :error
             :value "Connection broken"}))))))

(defn f->src [f]
  (cond (util/url? f) f
        (.exists (io/file f)) (io/file f)
        :else (io/resource f)))

(defn repl-compile-cljs
  ([f opts]
   (repl-compile-cljs f opts true))
  ([f opts reload-macros]
   (let [src (f->src f)
         compiled (binding [ana/*reload-macros* reload-macros]
                    (closure/compile
                     src
                     (assoc opts
                            :output-file
                            (closure/src-file->target-file src)
                            :force true
                            :mode :interactive)))]
     ;; copy over the original source file if source maps enabled
     (when-let [ns (and (:source-map opts) (first (:provides compiled)))]
       (spit
        (io/file (io/file (util/output-directory opts))
                 (util/ns->relpath ns (util/ext (:source-url compiled))))
        (slurp src)))
     compiled)))

(defn foreign->output-file [foreign opts]
  (let [output-path (closure/rel-output-path
                     (assoc foreign :foreign true)
                     opts)]
    (assoc foreign :file output-path)))

(defn refresh-cljs-deps [opts]
  (let [parse-js-fn (fn [js-file]
                      (-> js-file
                          slurp
                          string/split-lines
                          deps/parse-js-ns
                          (assoc :file js-file)))
        is-goog (fn [js-file]
                  (some #(.startsWith % "goog.")
                        (:provides js-file)))
        ups-foreign-libs (:ups-foreign-libs opts)
        js-files (deps/find-js-fs (:output-dir opts))
        js-files (map parse-js-fn js-files)
        js-files (filter #(and (seq (:provides %))
                               (not (is-goog %)))
                         js-files)
        js-files (map closure/map->javascript-file js-files)
        js-files (->> ups-foreign-libs
                      (map #(foreign->output-file % opts))
                      (into js-files))]
    (deps/dependency-order js-files)))

(defn repl-cljs-on-disk [compiled repl-opts opts]
  (let [sources (closure/add-dependencies
                 (merge repl-opts opts)
                 compiled)]
    (doseq [source sources]
      (closure/source-on-disk opts source))))

(defmulti init-opts :cljs-env-type)

(defn init-opts* [{{output-to :output-to} :compiler-env
                   {port :port main :main} :repl-env}]
  (let [output-dir (-> (file output-to) (.getAbsoluteFile) (.getParent))]
    {:compiler-opts (merge {:output-to (-> (file output-to) (.getAbsolutePath))
                            :output-dir output-dir
                            :optimizations :none
                            :recompile-dependents false
                            :preloads ['ewen.replique.cljs_env.repl
                                       'ewen.replique.cljs_env.browser]}
                           (when main {:main main}))
     :repl-opts {:analyze-path []
                 :port port}}))

(defmethod init-opts :browser [{{output-to :output-to} :compiler-env :as opts}]
  (let [opts (init-opts* opts)
        output-dir (get-in opts [:compiler-opts :output-dir])]
    (update-in opts [:repl-opts] merge
               {:serve-static true
                :static-dir ["." output-dir]})))

(defmethod init-opts :webapp [opts]
  (-> (init-opts* opts)
      (update-in [:repl-opts] merge {:serve-static false})))

;; Bypass the cljs load-javascript function in order to use the
;; race condition free "browser-eval" function
(defn load-javascript
  "Accepts a REPL environment, a list of namespaces, and a URL for a
  JavaScript file which contains the implementation for the list of
  namespaces. Will load the JavaScript file into the REPL environment
  if any of the namespaces have not already been loaded from the
  ClojureScript REPL."
  [repl-env provides url]
  (cljs.repl/-evaluate repl-env nil nil (slurp url)))

(defrecord BrowserEnv [wrapped eval-executor setup-ret]
  cljs.repl/IJavaScriptEnv
  (-setup [this opts] setup-ret)
  (-evaluate [this _ _ js]
    (try (-> (.submit eval-executor (make-eval-task js))
             (.get))
         (catch RejectedExecutionException e
           {:status :error
            :value "Connection broken"})))
  (-load [this provides url]
    (load-javascript this provides url))
  ;; We don't want the repl-env to be closed on cljs-repl exit
  (-tear-down [this] nil)
  cljs.repl/IReplEnvOptions
  (-repl-options [this]
    (cljs.repl/-repl-options wrapped))
  cljs.repl/IParseStacktrace
  (-parse-stacktrace [this st err opts]
    (cljs.repl/-parse-stacktrace wrapped st err opts))
  cljs.repl/IGetError
  (-get-error [this e env opts]
    (cljs.repl/-get-error wrapped e env opts)))

(defn tear-down-repl-env [repl-env]
  (cljs.repl/-tear-down (:wrapped repl-env))
  ;; Interrupt the currently executing task, if any
  ;; Pending tasks are returned
  (let [pendingTasks (.shutdownNow (:eval-executor repl-env))]
    (binding [*stopped-eval-executor?* true]
      (doseq [task pendingTasks]
        (.run task)))))

(defn custom-benv [benv eval-executor setup-ret]
  (merge (BrowserEnv. benv eval-executor setup-ret) benv))

;; Used instead of cljs.repl.browser to avoid compiling client.js.
;; client.js is not needed because the browser repl uses xhr with cors
;; instead of crosspagechannel
(defn setup [repl-env opts]
  (binding [cljs.repl.browser/browser-state (:browser-state repl-env)
            cljs.repl.browser/ordering (:ordering repl-env)
            cljs.repl.browser/es (:es repl-env)
            cljs.repl.server/state (:server-state repl-env)]
    (cljs.repl.server/start repl-env)))

(defn compute-asset-path [asset-path output-dir rel-path]
  (let [asset-path (if asset-path (str "\"" asset-path "\"") "null")
        output-dir (if output-dir (str "\"" output-dir "\"") "null")
        rel-path (if rel-path (str "\"" rel-path "\"") "null")]
    (str "(function(assetPath, outputDir, relPath) {
          if(assetPath) {
            return assetPath;
          }
          var computedAssetPath = assetPath? assetPath : outputDir;
          if(!outputDir ||  !relPath) {
            return computedAssetpath;
          }
          var endsWith = function(str, suffix) {
            return str.indexOf(suffix, str.length - suffix.length) !== -1;
          }
          var origin = window.location.protocol + \"//\" + window.location.hostname + (window.location.port ? ':' + window.location.port: '');
          var scripts = document.getElementsByTagName(\"script\");
          for(var i = 0; i < scripts.length; ++i) {
            var src = scripts[i].src;
            if(src && endsWith(src, relPath)) {
              var relPathIndex = src.indexOf(relPath);
              var originIndex = src.indexOf(origin);
              if(originIndex === 0) {
                return src.substring(origin.length+1, relPathIndex);
              }
            }
          }
          return computedAssetPath;
        })(" asset-path ", " output-dir ", " rel-path ");\n")))

(defn output-main-file [{:keys [closure-defines output-dir output-to]
                         :as opts} port]
  (let [closure-defines (json/write-str closure-defines)
        output-dir-uri (-> output-dir (File.) (.toURI))
        output-to-uri (-> output-to (File.) (.toURI))
        output-dir-path (-> (.normalize output-dir-uri)
                            (.toString))
        output-to-path (-> (.normalize output-to-uri)
                           (.toString))
        ;; If output-dir is not a parent dir of output-to, then
        ;; we don't try to infer the asset path because it may not
        ;; be possible.
        rel-path (if (and (.startsWith output-to-path
                                       output-dir-path)
                          (not= output-dir-path output-to-path))
                   (-> (.relativize output-dir-uri output-to-uri)
                       (.toString))
                   nil)]
    (cljsc/output-one-file
     opts
     (str "(function() {\n"
          "var assetPath = " (compute-asset-path (:asset-path opts) (util/output-directory opts) rel-path)
          "var CLOSURE_UNCOMPILED_DEFINES = " closure-defines ";\n"
          "if(typeof goog == \"undefined\") document.write('<script src=\"'+ assetPath +'/goog/base.js\"></script>');\n"
          "document.write('<script src=\"'+ assetPath +'/cljs_deps.js\"></script>');\n"
          #_"document.write('<script>if (typeof goog != \"undefined\") { goog.require(\"ewen.replique.cljs_env.repl\"); } else { console.warn(\"ClojureScript could not load :main, did you forget to specify :asset-path?\"); };</script>');\n"
          #_"document.write('<script>if (typeof goog != \"undefined\") { goog.require(\"ewen.replique.cljs_env.browser\"); } else { console.warn(\"ClojureScript could not load :main, did you forget to specify :asset-path?\"); };</script>');\n"
          (when (:main opts)
            (when-let [main (try (-> (:main opts)
                                     ana-api/parse-ns :ns)
                                 (catch Exception e nil))]
              (str "document.write('<script>if (typeof goog != \"undefined\") { goog.require(\"" (comp/munge main) "\"); } else { console.warn(\"ClojureScript could not load :main, did you forget to specify :asset-path?\"); };</script>');\n"
                   "document.write('<script>if (typeof goog != \"undefined\") {ewen.replique.cljs_env.repl.connect(\"http://localhost:" port "\");} else { console.warn(\"ClojureScript could not load :main, did you forget to specify :asset-path?\"); };</script>');")))
          "})();\n"))))

(defn init-browser-env
  ([comp-opts repl-opts]
   (init-browser-env comp-opts repl-opts true))
  ([comp-opts repl-opts output-main-file?]
   (let [compiler-env* (-> comp-opts
                           closure/add-implicit-options
                           cljs-env/default-compiler-env)
         repl-env* (apply cljs.repl.browser/repl-env (apply concat repl-opts))]
     (when @repl-env (tear-down-repl-env @repl-env))
     (cljs-env/with-compiler-env compiler-env*
       (comp/with-core-cljs nil
         (fn []
           (let [eval-executor (make-eval-executor repl-env*)
                 repl-env* (->> (setup repl-env* nil)
                                (custom-benv repl-env* eval-executor))]
             (try
               (let [port (-> @(:server-state repl-env*)
                              :socket
                              (.getLocalPort))
                     repl-src "ewen/replique/cljs_env/repl.cljs"
                     benv-src "ewen/replique/cljs_env/browser.cljs"
                     repl-compiled (repl-compile-cljs repl-src comp-opts false)
                     benv-compiled (repl-compile-cljs benv-src comp-opts false)]
                 (repl-cljs-on-disk
                  repl-compiled (#'cljs.repl/env->opts repl-env*) comp-opts)
                 (repl-cljs-on-disk
                  benv-compiled (#'cljs.repl/env->opts repl-env*) comp-opts)
                 (->> (refresh-cljs-deps comp-opts)
                      (closure/output-deps-file
                       (assoc comp-opts :output-to
                              (str (util/output-directory comp-opts)
                                   File/separator "cljs_deps.js"))))
                 (doto (io/file (util/output-directory comp-opts) "goog" "deps.js")
                   util/mkdirs
                   (spit (slurp (io/resource "goog/deps.js"))))
                 (when output-main-file?
                   (output-main-file comp-opts port))
                 (dosync
                  (ref-set compiler-env compiler-env*)
                  (ref-set repl-env repl-env*)))
               ;; Shutdown eval-executor ?
               (catch Throwable t
                 (tear-down-repl-env repl-env*)
                 (throw t))))))))))

(defmethod server/tooling-msg-handle :shutdown [msg]
  (with-tooling-response msg
    (when @repl-env (tear-down-repl-env @repl-env))
    (server/shutdown)
    {:shutdown true}))

(defn repl-caught [e repl-env opts]
  (binding [*out* server/tooling-err]
    (with-lock server/tooling-out-lock
      (-> (assoc {:type :eval
                  :error true
                  :repl-type :cljs
                  :session *session*
                  :ns (str ana/*cljs-ns*)}
                 :value (if (and (instance? IExceptionInfo e)
                                 (#{:js-eval-error :js-eval-exception}
                                  (:type (ex-data e))))
                          (:value (:error (ex-data e)))
                          (.getMessage e)))
          prn)))
  (cljs.repl/repl-caught e repl-env opts))

(defn cljs-repl []
  {:pre [(not (nil? (and @compiler-env @repl-env)))]}
  (let [out-lock (ReentrantLock.)]
    (swap! cljs-outs conj [*out* out-lock])
    (when-not (:connection @(:server-state @repl-env))
      (println (format "Waiting for browser to connect on port %d ..." (:port @repl-env))))
    (apply
     (partial cljs.repl/repl @repl-env)
     (->> (merge
           (:options @@compiler-env)
           {:compiler-env @compiler-env
            :caught repl-caught
            :print (fn [result]
                     (binding [*out* server/tooling-out]
                       (with-lock server/tooling-out-lock
                         (prn {:type :eval
                               :repl-type :cljs
                               :session *session*
                               :ns ana/*cljs-ns*
                               :result result})))
                     (with-lock out-lock
                       (println result)))
            :init (fn []
                    ;; Let the client know that we are entering a cljs repl
                    (binding [*out* server/tooling-out]
                      (with-lock server/tooling-out-lock
                        (prn {:type :eval
                              :repl-type :cljs
                              :session *session*
                              :ns ana/*cljs-ns*
                              :result "nil"})))
                    (cljs.repl/evaluate-form
                     @repl-env env "<cljs repl>"
                     (with-meta
                       `(~'ns ~'cljs.user
                         (:require ~@default-repl-requires))
                       {:line 1 :column 1})))})
          (apply concat)))
    (swap! cljs-outs disj [*out* out-lock])))

(comment
  (server/tooling-msg-handle
   {:type :set-cljs-env
    :cljs-env-type :browser
    :compiler-env {:output-to "out/main.js"}
    :repl-env {:port 9001}})

  (tear-down-repl-env @repl-env)

  @(:server-state @repl-env)
  @(:browser-state @repl-env)
  (:connection @(:server-state @repl-env))
  (.isClosed (:connection @(:server-state @repl-env)))
  (.isConnected (:connection @(:server-state @repl-env)))
  
  )


(comment
  {:settings
   {:custom-cljs-jar nil,
    :clj-jar-source "embedded",
    :downloaded-clj-jar "clojure-1.8.0.jar",
    :lein-source "embedded",
    :custom-clj-jar nil,
    :custom-lein-script nil,
    :sass-bin
    "/Users/egr/electron/resources/replique/runnables/replique_sass_3.2.5_0.0.1",
    :cljs-jar-source "embedded",
    :downloaded-cljs-jar "cljs-1.7.228.jar"},
   :repls
   {"64bedc2f-6bed-4606-8c00-ec4a87a83b20"
    {:directory "/Users/egr/clojure/clojurescript",
     :type :cljs,
     :cljs-env :webapp,
     :browser-env-random-port true,
     :webapp-env-random-port true,
     :browser-env-out "/Users/egr/clojure/clojurescript/out/main.js",
     :webapp-env-out "/Users/egr/clojure/clojurescript/out/main.js",
     :random-port true},
    "e8a61e4e-8753-4b68-960f-e832091b2b0c"
    {:browser-env-out nil,
     :directory "/Users/egr/electron/resources/replique",
     :browser-env-random-port true,
     :webapp-env-main
     "/Users/egr/electron/resources/replique/src/ewen/replique/ui/dashboard.cljs",
     :type :cljs,
     :webapp-env-out
     "/Users/egr/electron/resources/replique/bootstrap.js",
     :random-port true,
     :browser-env-port 455,
     :webapp-env-port 334,
     :cljs-env :replique,
     :webapp-env-random-port false,
     :browser-env-main nil},
    "9bef4632-56bf-4b4c-8592-314fc299222d"
    {:browser-env-out "/Users/egr/clojure/todo-ddom/out/main.js",
     :directory "/Users/egr/clojure/todo-ddom",
     :browser-env-random-port true,
     :webapp-env-main
     "/Users/egr/clojure/todo-ddom/src/todo_ddom/view.cljc",
     :type :cljs,
     :webapp-env-out
     "/Users/egr/clojure/todo-ddom/resources/public/javascript/main.js",
     :random-port true,
     :cljs-env :webapp,
     :webapp-env-random-port true},
    "f9bcca73-0e6f-4d1d-af62-3e5d7bb5ef14"
    {:directory "/Users/egr/clojure/clj-http",
     :type :clj,
     :cljs-env :browser,
     :browser-env-random-port true,
     :webapp-env-random-port true,
     :random-port true},
    "a03858d3-e526-4906-a0bd-e9c48c5a4619"
    {:directory "/Users/egr/clojure/prismic-kit-clj",
     :type :clj,
     :cljs-env :browser,
     :browser-env-random-port true,
     :webapp-env-random-port true,
     :random-port true},
    "fa8920a7-1136-4a10-aab2-8058c7947987"
    {:directory "/Users/egr/clojure/hiccup",
     :type :cljs,
     :cljs-env :browser,
     :browser-env-random-port true,
     :webapp-env-random-port true,
     :browser-env-out "/Users/egr/clojure/hiccup/out/main.js",
     :random-port true},
    "3b72e538-05ad-48e8-8f5e-7a2ed5a23260"
    {:directory "/Users/egr/clojure/inccup",
     :type :cljs,
     :cljs-env :browser,
     :browser-env-random-port true,
     :webapp-env-random-port true,
     :browser-env-out "/Users/egr/clojure/inccup/out/main.js",
     :random-port true}},
   :version "0.0.1"}
  )
