;;; qsem --- Quantified (counting) semaphores -*- lexical-binding: t -*-

;; Based on https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1 and
;; queue.el in ELPA

(require 'cl-lib)
(require 'cl-macs)

(cl-defstruct (qsem
               (:copier nil)
               (:constructor qsem-new
                             (&key
                              (name "qsem")
                              (mutex (make-mutex name))
                              (ready (make-condition-variable mutex name))
                              (size 1)
                              (avail size))))
  name mutex ready size avail)

(defun qsem-acquire (qsem)
  (with-mutex (qsem-mutex qsem)
    (while (= (qsem-avail qsem) 0)
      (condition-wait (qsem-ready qsem)))
    ;; (should (> (qsem-avail qsem) 0))
    (cl-decf (qsem-avail qsem))))

(defun qsem-release (qsem)
  (with-mutex (qsem-mutex qsem)
    (cl-incf (qsem-avail qsem))
    ;; (should (<= (qsem-avail qsem) (qsem-size qsem)))
    (condition-notify (qsem-ready qsem))))

(defmacro with-qsem (qsem &rest body)
  `(unwind-protect
       (progn
         (qsem-acquire ,qsem)
         ,@body)
     (qsem-release ,qsem)))

(provide 'qsem)

;;; qsem.el ends here
