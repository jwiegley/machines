;;; dllist --- Doubly-linked Lists -*- lexical-binding: t -*-

;; From https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)

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

(ert-deftest dllist-to-from-list-test ()
  (let ((x '(1 2 nil 4 5)))
    (should (equal x (dllist-to-list (dllist-from-list x))))))

(ert-deftest dllist-to-from-to-from-list-test ()
  (let ((x '(1 2 nil 4 5)))
    (should (equal x (dllist-to-list
                      (dllist-from-list
                       (dllist-to-list
                        (dllist-from-list x))))))))

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

(ert-deftest dllist-nth-test ()
  (let ((x (dllist-from-list '(1 2 nil 4 5))))
    (should (= 2 (dllist-value (dllist-nth x 1))))
    (should (= 4 (dllist-value (dllist-nth x 3))))))

(defun dllist-cyclic-from-list (list)
  "Make a cyclic doubly linked list from LIST."
  (when-let* ((x (dllist-from-list list)))
    (let ((end (dllist-nth x (1- (length list)))))
      (setf (dllist-next end) x)
      (setf (dllist-prev x) end)
      x)))

(ert-deftest dllist-cyclic-from-list-test ()
  (let ((x (dllist-cyclic-from-list '(1 2 nil 4 5))))
    (should (= 2 (dllist-value (dllist-nth x 1))))
    (should (= 2 (dllist-value (dllist-nth x 6))))))

(provide 'dllist)

;;; dllist.el ends here
