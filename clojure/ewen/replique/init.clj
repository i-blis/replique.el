(ns ewen.replique.init)

(def ^:const init-files
  ["clojure/ewen/replique/compliment/sources.clj"
   "clojure/ewen/replique/compliment/utils.clj"
   "clojure/ewen/replique/compliment/sources/ns_mappings.clj"
   "clojure/ewen/replique/compliment/sources/class_members.clj"
   "clojure/ewen/replique/compliment/sources/namespaces_and_classes.clj"
   "clojure/ewen/replique/compliment/sources/keywords.clj"
   "clojure/ewen/replique/compliment/sources/special_forms.clj"
   "clojure/ewen/replique/compliment/sources/local_bindings.clj"
   "clojure/ewen/replique/compliment/sources/resources.clj"
   "clojure/ewen/replique/compliment/context.clj"
   "clojure/ewen/replique/compliment/core.clj"])

(defn init [replique-root-dir]
  (println "Clojure" (clojure-version))
  (let [init-fn (fn []
                  (apply require
                         '[[clojure.repl :refer [source apropos
                                                 dir pst doc
                                                 find-doc]]
                           [clojure.java.javadoc :refer [javadoc]]
                           [clojure.pprint :refer [pp pprint]]])
                  (doseq [init-file init-files]
                    (load-file (str replique-root-dir init-file)))
                  (load-file
                   (str replique-root-dir
                        "clojure/ewen/replique/core.clj")))]
    (clojure.main/repl :init init-fn)))
