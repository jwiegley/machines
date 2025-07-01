;;; m-test --- Testing code for m.el tests -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)

(defvar m--test-include
  '(
    ;; m-compose-identities
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
         (let ((threads (all-threads))
               (procs (process-list)))
           (setq ts-queue-debug ,(not (null m--test-include)))
           (thread-last-error t)
           (unwind-protect
               (let ((worker (make-thread
                              #'(lambda ()
                                  (m--debug "m--test..1")
                                  ,@body)))
                     (limit 30000)
                     )
                 (m--debug "m--test..2")
                 (while (and (> limit 0)
                             (thread-live-p worker))
                   (m--debug "m--test..3")
                   (setq limit (1- limit))
                   (thread-yield)
                   (accept-process-output nil nil 10)
                   (sit-for 0.01 t))
                 (m--debug "m--test..4")
                 (when (<= limit 0)
                   (m--debug "m--test..5")
                   (thread-signal worker 'cancel-thread
                                  "timeout reached"))
                 (m--debug "m--test..6")
                 (thread-join worker)
                 (m--debug "m--test..7"))
             (setq ts-queue-debug nil))
           (should (equal threads (all-threads)))
           (should (equal procs (process-list))))
         (m--debug ,(concat test-name "...done"))))))

(provide 'm-test)

;;; m-test.el ends here
