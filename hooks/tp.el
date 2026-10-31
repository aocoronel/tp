;;; tp.el --- teleport around -*- lexical-binding: t; -*-

;; Copyright (C) 2026 aocoronel

;; This program is licensed under the 3-clause BSD license.

;; Author: aocoronel
;; URL: http://github.com/aocoronel
;; Version: 0.1.0

(defcustom tp-executable (executable-find "tp")
  "tp executable path"
  :type 'string)

(defcustom tp-find-file-function #'find-file
  "Default function to lookup files"
  :type 'function)

(defcustom tp-cd-callback-function #'find-file
  "Default callback function to lookup files"
  :type 'function)

;;;###autoload
(defun tp-run (async &rest args)
  (if async
    (apply #'start-process "tp" "*tp*" tp-executable args)
  ;; else
    (with-temp-buffer
      (if (equal 0 (apply #'call-process tp-executable nil t nil args))
        (buffer-string)
        (append-to-buffer "*tp*" (point-min) (point-max))
        (warn "tp failed. See buffer *tp* for more details.")))))

;;;###autoload
(defun tp-add (&optional path &rest _)
  (interactive "Dpath: ")
  (tp-run t (expand-file-name path)))

;;;###autoload
(defun tp-prune ()
  "Remove invalid entries"
  (interactive)
  (tp-run t "--prune"))

;;;###autoload
(defun tp-output (input &optional is-interactivep)
  (if is-interactivep
        (let ((buf-name "*tp query*"))
          (when (get-buffer buf-name)
            (kill-buffer buf-name))
          (switch-to-buffer-other-window buf-name)
          (with-current-buffer buf-name
            (erase-buffer)
            (insert input)
            (special-mode)))
      (remove "" (split-string input "\n"))))

;;;###autoload
(defun tp-query (query)
  (interactive "squery: ")
  (let ((results  (tp-run nil "--query" query)))
        (tp-output results (called-interactively-p 'any))))

;;;###autoload
(defun tp-list ()
  (interactive)
  (let ((results  (tp-run nil "--list")))
        (tp-output results (called-interactively-p 'any))))

;;;###autoload
(defun tp-open-with (query callback &optional noninteractive)
  (let* ((results
           (if query
             (tp-query query)
             (tp-list)))
         (match
           (concat (completing-read "path: " results nil t) "/")))
    (if (and (not noninteractive) (commandp callback))
      (call-interactively callback)
      (funcall callback match))))

;;;###autoload
(defun tp-find-file-with-query ()
  (interactive)
  (let ((query (read-string "query: ")))
    (tp-open-with query tp-find-file-function)))

;;;###autoload
(defun tp-find-file ()
  (interactive)
  (tp-open-with nil tp-find-file-function))

;;;###autoload
(defun tp-cd ()
  (interactive)
  (tp-open-with nil tp-cd-callback-function t))

;;;###autoload
(defun tp-cd-with-query ()
  (interactive)
  (let ((query (read-string "query: ")))
    (tp-open-with query tp-cd-callback-function t)))

(provide 'tp)

;;; tp.el ends here
