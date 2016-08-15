;;; replique2.el ---   -*- lexical-binding: t; -*-
;;; Package-Requires: ((emacs "24") (clojure-mode "4.0.1") (dash "2.12.0") (company "0.9.0") (dash-functional "1.2.0") (s "1.9.0"))
;;; Commentary:

;;; Code:

(require 'dash)
(require 'dash-functional)
(require 's)
(require 'comint)
(require 'clojure-mode)
(require 'replique-edn)
(require 'replique-async)
(require 'company)

(defmacro comment (&rest body)
  "Comment out one or more s-expressions."
  nil)

(defun replique/keyword-to-string (k)
  (substring (symbol-name k) 1))

(defun replique/message-nolog (format-string &rest args)
  (let ((message-log-max nil))
    (apply 'message format-string args)))

(defun replique/visible-buffers ()
  (let ((buffers '()))
    (walk-windows
     (lambda (window) (push (window-buffer window) buffers))
     nil 'visible)
    buffers))

;; New project REPL / new REPL buffer

;; Active tooling buffer
;; Active buffers for each tooling buffer
;; A list of all buffers

(defvar replique/repls nil)

(defun replique/plist->alist (plist)
  (let ((alist '()))
    (while plist
      (setq alist (push `(,(car plist) . ,(cadr plist)) alist))
      (setq plist (cddr plist)))
    alist))

(defun replique/repls-or-repl-by (filtering-fn source &rest args)
  (-let* ((pred (lambda (repl-props)
                  (and
                   (-all? (-lambda ((k . v))
                            (or (equal :error-on-nil k)
                                (not (plist-member args k))
                                (equal (plist-get args k) v)))
                          repl-props)
                   (-all? (-lambda ((k . v))
                            (-any? (-lambda ((repl-k . repl-v))
                                     (or (equal :error-on-nil k)
                                         (equal k repl-k)))
                                   repl-props))
                          (replique/plist->alist args)))))
          (found (funcall filtering-fn pred source)))
    (if (and (null found) (plist-get args :error-on-nil))
        (user-error "No started REPL")
      found)))

(defun replique/repl-by (&rest args)
  (apply 'replique/repls-or-repl-by '-first replique/repls args))

(defun replique/repls-by (&rest args)
  (apply 'replique/repls-or-repl-by '-filter replique/repls args))

(defun replique/active-repl (repl-type &optional error-on-nil)
  (if error-on-nil
      (replique/repl-by :repl-type repl-type :error-on-nil error-on-nil)
    (replique/repl-by :repl-type repl-type)))

(defun replique/guess-project-root-dir ()
  (or (locate-dominating-file default-directory "project.clj")
      default-directory))

(defun replique/replique-root-dir ()
  (-> (locate-library "replique")
      file-name-directory))




;; Auto completion

(defun replique/auto-complete-session (prefix company-callback props repl)
  (let* ((tooling-chan (cdr (assoc :tooling-chan props)))
         (repl-type (cdr (assoc :repl-type repl)))
         (msg-type (cond ((equal :clj repl-type)
                          :clj-completion)
                         ((equal :cljs repl-type)
                          :cljs-completion)
                         (t (error "Invalid REPL type: %s" repl-type)))))
    (replique/send-tooling-msg
     props
     `((:repl-type . ,msg-type)
       (:context . ,(replique/form-with-prefix))
       (:ns . (quote ,(cdr (assoc :ns repl))))
       (:prefix . ,prefix)))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (let ((err (gethash :error resp)))
         (if err
             (progn
               (message (replique-edn/pr-str err))
               (message "completion failed with prefix %s" prefix))
           (funcall company-callback (gethash :candidates resp)))))
     t)))

(defun replique/auto-complete* (prefix company-callback props msg-type)
  (let ((tooling-chan (cdr (assoc :tooling-chan props))))
    (replique/send-tooling-msg
     props
     `((:repl-type . ,msg-type)
       (:context . ,(replique/form-with-prefix))
       (:ns . (quote ,(make-symbol (clojure-find-ns))))
       (:prefix . ,prefix)))
    (replique-async/<!
     tooling-chan
     (lambda (resp)
       (let ((err (gethash :error resp)))
         (if err
             (progn
               (message (replique-edn/pr-str err))
               (message "completion failed with prefix %s" prefix))
           (funcall company-callback (gethash :candidates resp)))))
     t)))

(defun replique/auto-complete-clj (prefix company-callback props clj-repl)
  (replique/auto-complete* prefix company-callback props :clj-completion))

(defun replique/auto-complete-cljs (prefix company-callback props cljs-repl)
  (replique/auto-complete* prefix company-callback props :cljs-completion))

(defun replique/auto-complete (prefix company-callback)
  (replique/with-modes-dispatch
   (replique/mode . (-partial 'replique/auto-complete-session
                              prefix company-callback))
   (clojure-mode . (-partial 'replique/auto-complete-clj
                             prefix company-callback))
   (clojurescript-mode . (-partial 'replique/auto-complete-cljs
                                   prefix company-callback))))

(defun replique/skip-regexp-forward (regexp)
  (let ((data (match-data)))
    (when (looking-at regexp)
      (let ((match-length (-> (match-string 0)
                              length)))
        (forward-char match-length)
        (set-match-data data)
        (replique/skip-regexp-forward regexp)))
    (set-match-data data)))

(defun replique/skip-symbol-backward ()
  (skip-chars-backward (concat "^" clojure--sym-forbidden-1st-chars))
  (replique/skip-regexp-forward "#_\\|#\\|'"))

(defun replique/skip-symbol-forward ()
  (skip-chars-forward
   (concat "^" clojure--sym-forbidden-rest-chars)))

(defun replique/symbol-backward ()
  (save-excursion
    (let ((end (point)))
      (replique/skip-symbol-backward)
      (when (not (equal end (point)))
        (buffer-substring-no-properties (point) end)))))

(defun replique/symbol-at-point ()
  (save-excursion
    (replique/skip-symbol-backward)
    (let ((begin (point)))
      (replique/skip-symbol-forward)
      (when (not (equal begin (point)))
        (make-symbol
         (buffer-substring-no-properties begin (point)))))))

(defun replique/bounds-of-symbol-at-point ()
  (save-excursion
    (replique/skip-symbol-backward)
    (let ((begin (point)))
      (replique/skip-symbol-forward)
      (when (not (equal begin (point)))
        `(,begin . ,(point))))))

(defmacro replique/temporary-invisible-change (&rest forms)
  "Executes FORMS with a temporary buffer-undo-list, undoing on return.
The changes you make within FORMS are undone before returning.
But more importantly, the buffer's buffer-undo-list is not affected.
This allows you to temporarily modify read-only buffers too."
  `(let* ((buffer-undo-list)
          (modified (buffer-modified-p))
          (inhibit-read-only t)
          (temporary-res nil)
          (temporary-point (point)))
     (unwind-protect
         (setq temporary-res (progn ,@forms))
       (primitive-undo (length buffer-undo-list) buffer-undo-list)
       (set-buffer-modified-p modified)
       (goto-char temporary-point))
     temporary-res))

(defun replique/strip-text-properties(txt)
  (set-text-properties 0 (length txt) nil txt)
  txt)

(defun replique/form-with-prefix* ()
  (let ((bounds (replique/bounds-of-symbol-at-point)))
    (replique/temporary-invisible-change
     (if bounds
         (progn (delete-region (car bounds) (cdr bounds))
                (insert "__prefix__")
                (thing-at-point 'defun))
       nil))))

;; Execute in a temp buffer because company-mode expects the current buffer
;; to not change at all
(defun replique/form-with-prefix ()
  (let ((defun-bounds (bounds-of-thing-at-point 'defun)))
    (when defun-bounds
      (let* ((point-offset-backward (- (cdr defun-bounds) (point)))
             (defun-content (buffer-substring (car defun-bounds)
                                              (cdr defun-bounds))))
        (with-temp-buffer
          (insert defun-content)
          (backward-char point-offset-backward)
          (replique/form-with-prefix*))))))

(defun replique/company-backend (command &optional arg &rest ignored)
  (interactive (list 'interactive))
  (cond
   ((equal command 'interactive)
    (company-begin-backend 'replique/company-backend))
   ((equal command 'prefix) (when (or (derived-mode-p 'clojure-mode)
                                      (derived-mode-p 'replique/mode))
                              (replique/symbol-backward)))
   ((equal command 'candidates)
    `(:async . ,(-partial 'replique/auto-complete arg)))))

(defun replique/comint-is-closed-sexpr (start limit)
  (let ((depth (car (parse-partial-sexp start limit))))
    (if (<= depth 0) t nil)))

(defun replique/comint-send-input ()
  (interactive)
  (let* ((buff (current-buffer))
         (repl (replique/repl-by :buffer buff))
         (eval-chan (cdr (assoc :eval-chan repl)))
         (proc (get-buffer-process buff)))
    (if (not proc) (user-error "Current buffer has no process")
      (widen)
      (let* ((pmark (process-mark proc)))
        (cond (;; Point is at the end of the line and the sexpr is
               ;; terminated
               (and (equal (point) (point-max))
                    (replique/comint-is-closed-sexpr pmark (point)))
               (comint-send-input))
              ;; Point is after the prompt but (before the end of line or
              ;; the sexpr is not terminated)
              ((comint-after-pmark-p) (comint-accumulate))
              ;; Point is before the prompt. Do nothing.
              (t nil))))))

(defun replique/format-eval-message (msg)
  (if (gethash :error msg)
      (let ((value (gethash :value msg))
            (repl-type (gethash :repl-type msg))
            (ns (gethash :ns msg)))
        (if (s-starts-with-p "Error:" value)
            (format "(%s) %s=> %s"
                    (replique/keyword-to-string repl-type) ns value)
          (format "(%s) %s=> Error: %s"
                  (replique/keyword-to-string repl-type) ns value)))
    (let ((result (gethash :result msg))
          (repl-type (gethash :repl-type msg))
          (ns (gethash :ns msg)))
      (format "(%s) %s=> %s"
              (replique/keyword-to-string repl-type) ns result))))

(defun replique/display-eval-result (msg buff)
  (when (not (-contains? (replique/visible-buffers) buff))
    (replique/message-nolog
     (replique/format-eval-message msg))))

(defun replique/format-load-file-message (msg)
  (if (gethash :error msg)
      (let ((value (gethash :value msg))
            (repl-type (gethash :repl-type msg)))
        (if (s-starts-with-p "Error:" value)
            (format "(%s) load-file: %s"
                    (replique/keyword-to-string repl-type) value)
          (format "(%s) load-file: Error: %s"
                  (replique/keyword-to-string repl-type) value)))
    (let ((result (gethash :result msg))
          (repl-type (gethash :repl-type msg)))
      (format "(%s) load-file: %s"
              (replique/keyword-to-string repl-type) result))))

(defun replique/display-load-file-result (msg buff)
  (when (not (-contains? (replique/visible-buffers) buff))
    (replique/message-nolog
     (replique/format-load-file-message msg))))

(defun replique/display-load-file-results (msg1 msg2 clj-buff cljs-buff)
  (let ((visible-buffers (replique/visible-buffers))
        (clj-msg (-first (lambda (msg)
                           (equal :clj (gethash :repl-type msg)))
                         (list msg1 msg2)))
        (cljs-msg (-first (lambda (msg)
                            (equal :cljs (gethash :repl-type msg)))
                          (list msg1 msg2))))
    (cond ((and (not (-contains? visible-buffers clj-buff))
                (not (-contains? visible-buffers cljs-buff)))
           (replique/message-nolog
            "%s\n%s"
            (replique/format-load-file-message clj-msg)
            (replique/format-load-file-message cljs-msg)))
          ((not (-contains? visible-buffers clj-buff))
           (replique/message-nolog
            (replique/format-load-file-message clj-msg)))
          ((not (-contains? visible-buffers cljs-buff))
           (replique/message-nolog
            (replique/format-load-file-message cljs-msg))))))

(defmacro replique/with-modes-dispatch (&rest modes-alist)
  (let* ((props-sym (make-symbol "props-sym"))
         (clj-repl-sym (make-symbol "clj-repl-sym"))
         (cljs-repl-sym (make-symbol "cljs-repl-sym"))
         (clj-buff-sym (make-symbol "clj-buff-sym"))
         (cljs-buff-sym (make-symbol "cljs-buff-sym"))
         (dispatch-code
          (mapcar
           (lambda (item)
             (let ((m (car item))
                   (f (cdr item)))
               (cond ((equal 'clojure-mode m)
                      `((equal 'clojure-mode major-mode)
                        (if ,clj-buff-sym
                            (funcall ,f ,props-sym ,clj-repl-sym)
                          (user-error "No active Clojure REPL"))))
                     ;; No active clojure REPL is required
                     ;; For example, it is possible to load a clojure file
                     ;; when only a clojurescript REPL is active because of
                     ;; macro reloading
                     ((equal 'clojure-mode* m)
                      `((equal 'clojure-mode major-mode)
                        (if (or ,clj-buff-sym ,cljs-buff-sym)
                            (funcall ,f
                                     ,props-sym
                                     ,clj-repl-sym ,cljs-repl-sym)
                          (user-error
                           "No active Clojure or Clojurescript REPL"))))
                     ((equal 'clojurescript-mode m)
                      `((equal 'clojurescript-mode major-mode)
                        (if ,cljs-buff-sym
                            (funcall ,f ,props-sym ,cljs-repl-sym)
                          (user-error "No active Clojurescript REPL"))))
                     ((equal 'clojurec-mode m)
                      `((equal 'clojurec-mode major-mode)
                        (if (or ,clj-buff-sym ,cljs-buff-sym)
                            (funcall ,f ,props-sym
                                     ,clj-repl-sym ,cljs-repl-sym)
                          (user-error
                           "No active Clojure or Clojurescript REPL"))))
                     ((equal 'css-mode m)
                      `((equal 'css-mode major-mode)
                        (if ,cljs-buff-sym
                            (funcall ,f ,props-sym ,cljs-repl-sym)
                          (user-error
                           "No active Clojurescript REPL"))))
                     ((equal 'scss-mode m)
                      `((equal 'scss-mode major-mode)
                        (if ,cljs-buff-sym
                            (funcall ,f ,props-sym ,cljs-repl-sym)
                          (user-error
                           "No active Clojurescript REPL"))))
                     ((equal 'replique/mode m)
                      `((equal 'replique/mode major-mode)
                        (funcall ,f ,props-sym
                                 (replique/repl-by :buffer (current-buffer))))))))
           modes-alist))
         (dispatch-code (append dispatch-code
                                '((t (user-error
                                      "Cannot eval from major mode: %s"
                                      major-mode))))))
    `(let* ((,props-sym (replique/active-repl :tooling t))
            (,clj-repl-sym (replique/active-repl :clj))
            (,cljs-repl-sym (replique/active-repl :cljs))
            (,clj-buff-sym (cdr (assoc :buffer ,clj-repl-sym)))
            (,cljs-buff-sym (cdr (assoc :buffer ,cljs-repl-sym))))
       (cond ,@dispatch-code))))

(defun replique/comint-kill-input ()
  (let ((pmark (process-mark (get-buffer-process (current-buffer)))))
    (if (> (point) (marker-position pmark))
        (let ((killed (buffer-substring-no-properties pmark (point))))
          (kill-region pmark (point))
          killed)
      "")))

(defun replique/comint-send-input-from-source (input)
  (let ((process (get-buffer-process (current-buffer))))
    (when (not process)
      (user-error "Current buffer has no process"))
    (goto-char (point-max))
    (let ((old-input (replique/comint-kill-input)))
         (goto-char (process-mark process))
         (insert input)
         (replique/comint-send-input)
         (goto-char (process-mark process))
         (insert old-input))))

(defun replique/send-input-from-source-clj-cljs
    (input display-result-fn props repl)
  (let ((buff (cdr (assoc :buffer repl)))
        (eval-chan (cdr (assoc :eval-chan repl))))
    (with-current-buffer buff
      (replique/comint-send-input-from-source input))
    (replique-async/<!
     eval-chan
     (lambda (msg)
       (when msg
         (funcall display-result-fn msg buff)))
     t)))

(defun replique/send-input-from-source-cljc
    (input-clj input-cljs display-result-fn display-results-fn
               props clj-repl cljs-repl)
  (let ((clj-buff (cdr (assoc :buffer clj-repl)))
        (clj-eval-chan (cdr (assoc :eval-chan clj-repl)))
        (cljs-buff (cdr (assoc :buffer cljs-repl)))
        (cljs-eval-chan (cdr (assoc :eval-chan cljs-repl))))
    (when clj-buff
      (with-current-buffer clj-buff
        (replique/comint-send-input-from-source input-clj)))
    (when cljs-buff
      (with-current-buffer cljs-buff
        (replique/comint-send-input-from-source input-cljs)))
    (cond ((and clj-buff cljs-buff)
           (let ((chan (replique-async/chan)))
             (replique-async/<!
              clj-eval-chan
              (lambda (msg)
                (replique-async/put! chan msg)))
             (replique-async/<!
              cljs-eval-chan
              (lambda (msg)
                (replique-async/put! chan msg)))
             (replique-async/<!
              chan
              (lambda (msg1)
                (replique-async/<!
                 chan
                 (lambda (msg2)
                   (funcall display-results-fn
                            msg1 msg2 clj-buff cljs-buff))))
              t)))
          (clj-buff
           (replique-async/<!
                     clj-eval-chan
                     (lambda (msg)
                       (when msg
                         (funcall display-result-fn msg clj-buff)))
                     t))
          (cljs-buff
           (replique-async/<!
                     cljs-eval-chan
                     (lambda (msg)
                       (when msg
                         (funcall display-result-fn msg cljs-buff)))
                     t)))))

(defun replique/send-input-from-source-dispatch (input)
  (replique/with-modes-dispatch
   (clojure-mode . (-partial
                    'replique/send-input-from-source-clj-cljs
                    input 'replique/display-eval-result))
   (clojurescript-mode . (-partial
                          'replique/send-input-from-source-clj-cljs
                          input 'replique/display-eval-result))
   (clojurec-mode . (-partial
                     'replique/send-input-from-source-cljc
                     input input
                     'replique/display-eval-result
                     'replique/display-eval-results))))

(defun replique/eval-region (start end)
  "Eval the currently highlighted region."
  (interactive "r")
  (let ((input (filter-buffer-substring start end)))
    (replique/send-input-from-source-dispatch input)))

(defun replique/eval-last-sexp ()
  "Eval the previous sexp."
  (interactive)
  (replique/eval-region
   (save-excursion
     (clojure-backward-logical-sexp 1) (point))
   (point)))

(defun replique/eval-defn ()
  "Eval the current defn expression."
  (interactive)
  (replique/send-input-from-source-dispatch (thing-at-point 'defun)))

(defun replique/load-file-clj (file-path props clj-repl cljs-repl)
  (if clj-repl
      (replique/send-input-from-source-clj-cljs
       (format "(clojure.core/load-file \"%s\")" file-path)
       'replique/display-load-file-result
       props clj-repl)
    (replique/send-input-from-source-clj-cljs
     (format "(ewen.replique.cljs-env.macros/load-file :clj \"%s\")"
             file-path)
     'replique/display-load-file-result
     props cljs-repl)))

(defun replique/load-file-cljs (file-path props cljs-repl)
  (replique/send-input-from-source-clj-cljs
   (format "(ewen.replique.cljs-env.macros/load-file \"%s\")"
           file-path)
   'replique/display-load-file-result
   props cljs-repl))

(defun replique/load-file-cljc (file-path props clj-repl cljs-repl)
  (replique/send-input-from-source-cljc
   (format "(clojure.core/load-file \"%s\")" file-path)
   (format "(ewen.replique.cljs-env.macros/load-file \"%s\")" file-path)
   'replique/display-load-file-result
   'replique/display-load-file-results
   props clj-repl cljs-repl))

(defun replique/load-file ()
  "Load a file in a replique REPL"
  (interactive)
  (let ((file-path (buffer-file-name)))
    (comint-check-source file-path)
    (replique/with-modes-dispatch
     (clojure-mode* . (-partial 'replique/load-file-clj file-path))
     (clojurescript-mode . (-partial 'replique/load-file-cljs file-path))
     (clojurec-mode . (-partial 'replique/load-file-cljc file-path))
     (css-mode . (-partial 'replique/load-css file-path))
     (scss-mode . (-partial 'replique/load-scss file-path)))))

(defcustom replique/prompt "^[^=> \n]+=> *"
  "Regexp to recognize prompts in the replique mode."
  :type 'regexp
  :group 'replique)

(defvar replique/mode-hook '()
  "Hook for customizing replique mode.")

(defvar replique/mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (define-key map "\C-m" 'replique/comint-send-input)
    map))

(define-derived-mode replique/mode comint-mode "Replique"
  "Commands:\\<replique/mode-map>"
  (setq comint-prompt-regexp replique/prompt)
  (setq comint-prompt-read-only t)
  (setq mode-line-process '(":%s"))
  (clojure-mode-variables)
  (clojure-font-lock-setup)
  (add-to-list 'company-backends 'replique/company-backend))

(defvar replique/minor-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-r" 'replique/eval-region)
    (define-key map "\C-x\C-e" 'replique/eval-last-sexp)
    (define-key map "\C-\M-x" 'replique/eval-defn)
    (define-key map "\C-c\C-l" 'replique/load-file)
    (define-key map "\C-c\M-n" 'replique/in-ns)
    (define-key map "\M-." 'replique/jump-to-definition)
    (define-key map "\M-," 'pop-tag-mark)
    (easy-menu-define replique/minor-mode-menu map
      "Replique Minor Mode Menu"
      '("Replique"
        ["Eval region" replique/eval-region t]
        ["Eval last sexp" replique/eval-last-sexp t]
        ["Eval defn" replique/eval-defn t]
        "--"
        ["Load file" replique/load-file t]
        "--"
        ["Set REPL ns" replique/in-ns t]
        "--"
        ["Jump to definition" replique/jump-to-definition t]
        ))
    map))

(defvar replique/generic-minor-mode-map
  (let ((map (make-sparse-keymap)))
    map))

;;;###autoload
(define-minor-mode replique/minor-mode
  "Minor mode for interacting with the replique process buffer.

The following commands are available:

\\{replique/minor-mode-map}"
  :lighter "Replique" :keymap replique/minor-mode-map
  (add-to-list 'company-backends 'replique/company-backend))

(defun replique/lein-command (port)
  `("/Users/egr/bin/lein" "update-in" ":source-paths" "conj"
    ,(format "\"%ssrc\"" (replique/replique-root-dir))
    "--" "run" "-m" "ewen.replique.main/-main"
    ,(format "{:type :clj :port %s}" (number-to-string port))))

(defun replique/is-lein-project (directory)
  (file-exists-p (expand-file-name "project.clj" directory)))

(defun replique/process-filter-chan (proc)
  (let ((chan (replique-async/chan)))
    (set-process-filter
     proc (lambda (proc string)
            (replique-async/put! chan string)))
    chan))

(defun replique/is-valid-port-nb? (port-nb)
  (< -1 port-nb 65535))

(defun replique/close-tooling-repl (repl)
  (-let (((&alist :network-proc tooling-network-proc :proc tooling-proc) repl))
    (when (process-live-p tooling-network-proc)
      (set-process-filter tooling-network-proc (lambda (proc string) nil))
      (process-send-eof tooling-network-proc))
    (when (process-live-p tooling-proc)
      (delete-process tooling-proc))
    (setq replique/repls (delete repl replique/repls))))

(defun replique/close-repl (repl-props)
  (-let* (((&alist :buffer buffer :host host :port port) repl-props)
          (proc (get-buffer-process buffer)))
    (setq replique/repls (delete repl-props replique/repls))
    (when (and proc (process-live-p proc))
      (process-send-eof proc))
    ;; If the only repl left is a tooling repl, then close it
    (let ((other-repls (replique/repls-by :host host :port port)))
      (when (-all? (-lambda ((&alist :repl-type repl-type))
                     (equal :tooling repl-type))
                   other-repls)
        (mapcar 'replique/close-tooling-repl other-repls)))))

(defun replique/close-repls (host port)
  (let* ((repls (replique/repls-by :host host :port port))
         (not-tooling-repls (-filter (-lambda ((&alist :repl-type repl-type))
                                       (not (equal repl-type :tooling)))
                                     repls))
         (tooling-repls (-filter (-lambda ((&alist :repl-type repl-type))
                                   (equal repl-type :tooling))
                                 repls)))
    (mapcar (lambda (repl)
              (replique/close-repl))
            not-tooling-repls)
    (mapcar (lambda (repl)
              (replique/remove-from-active-repls host port)
              (replique/close-tooling-repl repl))
            tooling-repls)))

(defun replique/on-tooling-repl-close
    (tooling-chan-src host port process event)
  (cond ((string= "deleted\n" event)
         (replique/close-repls host port))
        ((string= "connection broken by remote peer\n" event)
         (replique/close-repls host port))
        (t nil)))

(defun replique/make-tooling-repl (host port directory out-chan)
  (let* ((default-directory directory)
         (repl-cmd (replique/lein-command port))
         (proc (apply 'start-file-process directory nil (car repl-cmd) (cdr repl-cmd)))
         (chan (replique/process-filter-chan proc)))
    (replique-async/<!
     chan (lambda (x)
            (set-process-filter proc (lambda (proc string) nil))
            ;; Catch errors during the clojure process startup
            (condition-case nil
                (let* ((repl-infos (replique-edn/read-string x))
                       (host (gethash :host repl-infos))
                       (port (gethash :port repl-infos))
                       (directory (replique/normalize-directory-name
                                   (gethash :directory repl-infos)))
                       (network-proc (open-network-stream directory nil host port))
                       (tooling-chan (replique/process-filter-chan network-proc)))
                  (set-process-sentinel
                   network-proc (-partial 'replique/on-tooling-repl-close chan host port))
                  ;; Discard the prompt
                  (replique-async/<!
                   tooling-chan (lambda (x)
                                  (process-send-string
                                   network-proc
                                   "(ewen.replique.server/shared-tooling-repl)\n")
                                  (let* ((tooling-chan (-> tooling-chan
                                                           replique/edn-read-stream
                                                           replique/dispatch-eval-msg))
                                         (repl-props `((:directory . ,directory)
                                                       (:repl-type . :tooling)
                                                       (:proc . ,proc)
                                                       (:network-proc . ,network-proc)
                                                       (:host . ,host)
                                                       (:port . ,port)
                                                       (:chan . ,tooling-chan))))
                                    (push repl-props replique/repls)
                                    (replique-async/put! out-chan repl-props)))))
              (error (error "Error while starting the REPL: %s" x)))))))

(defun replique/on-repl-close (host port buffer process event)
  (let ((closing-repl (replique/repl-by :host host :port port :buffer buffer)))
    (when closing-repl
      (cond ((string= "deleted\n" event)
             (replique/close-repl closing-repl))
            ((string= "connection broken by remote peer\n" event)
             (with-current-buffer buffer
               (save-excursion
                 (goto-char (point-max))
                 (insert (concat "\n" event "\n"))))
             (replique/close-repl closing-repl))
            (t nil)))))

(defun replique/make-repl (buffer-name host port make-active)
  (-let* ((buff (get-buffer-create buffer-name))
          (buff (make-comint-in-buffer buffer-name buff `(,host . ,port)))
          (proc (get-buffer-process buff))
          (chan-src (replique/process-filter-chan proc))
          (repl-cmd (format "(ewen.replique.server/repl :clj)\n")))
    (set-process-sentinel
     proc (-partial 'replique/on-repl-close host port buff))
    ;; Discard the prompt
    (replique-async/<!
     chan-src
     (lambda (x)
       (let ((chan (replique/edn-read-stream chan-src)))
         (process-send-string proc "(ewen.replique.server/tooling-repl)\n")
         ;; Get the session number
         (process-send-string proc "clojure.core.server/*session*\n")
         (replique-async/<!
          chan
          (lambda (resp)
            (let ((session (gethash :client resp)))
              ;; Reset process filter to the default one
              (set-process-filter proc 'comint-output-filter)
              (set-buffer buff)
              (replique/mode)
              (process-send-string proc repl-cmd)
              (let ((repl `((:host . ,host)
                            (:port . ,port)
                            (:repl-type . :clj)
                            (:session . ,session)
                            (:ns . 'user)
                            (:buffer . ,buff)
                            (:eval-chan . ,(replique-async/chan)))))
                (push repl replique/repls))
              (when t
                (pop-to-buffer buff))))))))))

(defun replique/clj-buff-name (directory repl-type)
  (let ((repl-type-string (replique/keyword-to-string repl-type)))
    (generate-new-buffer-name
     (format "*replique*%s*%s*"
             (file-name-nondirectory (directory-file-name directory))
             repl-type-string))))

(defun replique/normalize-directory-name (directory)
  (file-name-as-directory (file-truename directory)))

;;;###autoload
(defun replique/repl (&optional directory host port)
  (interactive            
   (let ((directory (read-directory-name
                     "Project directory: " (replique/guess-project-root-dir) nil t))
         (host "127.0.0.1")
         (port (read-number "Port number: " 0)))
     ;; Normalizing the directory name is necessary in order to be able to search repls
     ;; by directory name
     (list (replique/normalize-directory-name directory) host port)))
  (if (not (replique/is-valid-port-nb? port))
      (message "Invalid port number: %d" port)
    (progn
      (when (not (replique/is-lein-project directory))
        (error "Not a lein project"))
      (let* ((existing-repl (replique/repl-by
                             :directory directory
                             :repl-type :tooling))
             (tooling-repl-chan (replique-async/chan)))
        (if existing-repl
            (replique-async/put! tooling-repl-chan existing-repl)
          (replique/make-tooling-repl host port directory tooling-repl-chan))
        (replique-async/<!
         tooling-repl-chan
         (-lambda ((&alist :directory directory
                           :host host :port port
                           :chan tooling-chan))
           (let* ((buff-name (replique/clj-buff-name directory :clj)))
             (replique/make-repl buff-name host port t))
           (comment (replique/close-repls host (cdr (assoc :port tooling-repl))))))))))

(defvar replique/edn-tag-readers
  `((error . identity)
    (object . identity)))

(defun replique/dispatch-eval-msg* (in-chan out-chan)
  (replique-async/<!
   in-chan
   (lambda (msg)
     (cond ((equal :eval (gethash :type msg))
            (let ((repl (replique/repl-by
                         :repl-type (gethash :repl-type msg)
                         :session (gethash :client (gethash :session msg)))))
              (when repl
                (setcdr (assoc :ns repl) (gethash :ns msg))
                (replique-async/put! (cdr (assoc :eval-chan repl)) msg)))
            (replique/dispatch-eval-msg* in-chan out-chan))
           (t (replique-async/put! out-chan msg)
              (replique/dispatch-eval-msg* in-chan out-chan))))))

(defun replique/dispatch-eval-msg (in-chan)
  (let ((out-chan (replique-async/chan)))
    (replique/dispatch-eval-msg* in-chan out-chan)
    out-chan))

(defun replique/edn-read-stream* (chan-in chan-out edn-state)
  (replique-async/<!
   chan-in
   (lambda (s)
     (let ((continue t))
       (while continue
         (let* ((reader (replique-edn/reader nil :str s))
                (result-state (assoc :result-state
                                     (symbol-value edn-state)))
                (result-state (if result-state (cdr result-state) nil)))
           (if (equal :waiting (symbol-value result-state))
               (replique-edn/set-reader edn-state reader)
             (-> (replique-edn/init-state reader edn-state)
                 (replique-edn/set-tagged-readers
                  replique/edn-tag-readers)))
           (replique-edn/read edn-state)
           (-let (((&alist :result result
                           :result-state result-state)
                   (symbol-value edn-state))
                  (rest-string
                   (replique-edn/reader-rest-string reader)))
             (when (and
                    (not (equal :waiting (symbol-value result-state)))
                    (car (symbol-value result)))
               (replique-async/put!
                chan-out (car (symbol-value result))))
             (if (not (string= "" rest-string))
                 (setq s rest-string)
               (setq continue nil)))))
       (replique/edn-read-stream* chan-in chan-out edn-state)))))

(defun replique/edn-read-stream (chan-in)
  (let ((edn-state (-> (replique-edn/reader nil :str "")
                       replique-edn/init-state
                       (replique-edn/set-tagged-readers
                        replique/edn-tag-readers)))
        (chan-out (replique-async/chan)))
    (replique/edn-read-stream* chan-in chan-out edn-state)
    chan-out))

(comment
 (defvar in-chan (replique-async/chan))
 (defvar out-chan (replique/edn-read-stream in-chan))

 (replique-async/<!
  out-chan
  (lambda (x)
    (print x)))

 (replique-async/put! in-chan "3 ")
 )

(provide 'replique2)

;;; replique.el ends here
