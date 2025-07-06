;;; dllist.el --- Doubly-linked Lists -*- lexical-binding: t -*-

;; From https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1

(require 'cl-lib)
(require 'cl-macs)

(cl-defstruct dllist value (prev nil) (next nil))

(defun dllist-from-list (list)
  "Create a doubly linked list with LIST's elements."
  (when list
    (let* ((dll (make-dllist :value (pop list)))
           (prev dll))
      (dolist (v list)
        (let ((next (make-dllist :value v)))
          (setf (dllist-next prev) next)
          (setf (dllist-prev next) prev)
          (setq prev next)))
      dll)))

(defun dllist-to-list (dll)
  "Convert a doubly linked list DLL back into a regular list."
  (cl-loop for x = dll then (dllist-next x)
           while x
           for y = (dllist-value x)
           collect y))

(defun dllist-nth (dll n)
  "Get Nth node of the doubly linked list DLL.
N may be negative to look backwards."
  (let ((node dll))
    (dotimes (i (abs n))
      (setq node
            (if (< n 0)
                (dllist-prev node)
              (dllist-next node))))
    node))

(defun dllist-cyclic-from-list (list)
  "Make a cyclic doubly linked list from LIST."
  (when-let* ((x (dllist-from-list list)))
    (let ((end (dllist-nth x (1- (length list)))))
      (setf (dllist-next end) x)
      (setf (dllist-prev x) end)
      x)))

(provide 'dllist)

;;; dllist.el ends here
