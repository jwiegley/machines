;;; m-test --- Testing code for m.el tests -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)

(defvar m--test-include
  '(
    ;; m-compose!-identities
    ;; m-drop
    ;; m-fibonacci
    ;; m-fibonacci-iter
    ;; m-filter
    ;; m-for
    ;; m-from-list
    ;; m-from-list-iter
    ;; m-funcall
    ;; m-funcall-bad
    ;; m-generator
    ;; m-head
    ;; m-identity
    ;; m-iterator
    ;; m-map
    ;; m-process
    ;; m-process-compose
    ;; m-process-drain
    ;; m-take
    ;; m-gptel
    )
  )

(defmacro m--test (sym &rest body)
  (declare (indent 1))
  (when (or (null m--test-include)
            (memq sym m--test-include))
    (let ((test-name (concat (symbol-name sym) "-test")))
      `(ert-deftest ,(intern test-name) ()
         (message ,(concat test-name "..."))
         (sit-for 0)
         (let ((threads (all-threads))
               (procs (process-list)))
           (setq ts-queue-debug ,(not (null m--test-include)))
           (thread-last-error t)
           (unwind-protect
               ,@body
             (setq ts-queue-debug nil))
           (should (equal threads (all-threads)))
           (should (equal procs (process-list))))
         (m--debug ,(concat test-name "...done"))))))

(provide 'm-test)

;;; m-test.el ends here
