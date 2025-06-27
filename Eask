;; -*- mode: eask; lexical-binding: t -*-

(package "machines"
         "1.0.0"
         "Composible, asynchronous streaming machines for Emacs Lisp")

(website-url "https://github.com/jwiegley/machines")
(keywords "programming" "lisp")

(package-file "m.el")

(files
 "dllist.el"
 "fifo.el"
 "ts-queue.el"
 "m.el"
 )

(script "test" "echo \"Error: no test specified\" && exit 1")

(source "gnu")
(source "melpa")

(depends-on "emacs" "30.1")
(development
 (depends-on "ert-runner"))

(add-hook 'eask-before-compile-hook
           (lambda ()
             (setq byte-compile-error-on-warn t)
             (setq byte-compile-docstring-max-column 1000)))
