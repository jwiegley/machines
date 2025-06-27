;;; fifo --- First-In First-Out queue -*- lexical-binding: t -*-

;; From https://gist.github.com/jordonbiondo/d3679eafbe9e99a5dff1

(require 'cl-lib)
(require 'cl-macs)
(require 'ert)
(require 'dllist)

(cl-defstruct fifo (dllist nil))

(defun fifo-push (fifo elem)
  "Push ELEM onto the back of FIFO."
  (let ((dll (fifo-dllist fifo)))
    (if dll
        (let ((n (dllist-from-list (list elem))))
          (setf (dllist-next (dllist-prev dll)) n)
          (setf (dllist-prev n) (dllist-prev dll))
          (setf (dllist-prev dll) n)
          (setf (dllist-next n) dll))
      (setf (fifo-dllist fifo)
            (dllist-cyclic-from-list (list elem))))))

(defun fifo-from-list (list)
  "Create a new FIFO queue containing LIST initially."
  (make-fifo :dllist (dllist-cyclic-from-list list)))

(defun fifo-pop (fifo)
  "Pop and return the first element off FIFO.
This raises an error if the FIFO is empty."
  (cl-assert (not (fifo-empty-p fifo)))
  (let* ((dll (fifo-dllist fifo))
         (val (dllist-value dll)))
    (if (eql dll (dllist-next dll))
        (setf (fifo-dllist fifo) nil)
      (setf (dllist-next (dllist-prev dll)) (dllist-next dll))
      (setf (dllist-prev (dllist-next dll)) (dllist-prev dll))
      (setf (fifo-dllist fifo) (dllist-next dll)))
    val))

(defun fifo-empty-p (fifo)
  "Return non-nil if the FIFO is empty."
  (null (fifo-dllist fifo)))

(defun fifo-length (fifo)
  "Return the number of elements in FIFO."
  (let* ((dll (fifo-dllist fifo))
         (next (dllist-next dll))
         (len (if next 1 0)))
    (while (and dll next (not (eql dll next)))
      (cl-incf len)
      (setq next (dllist-next next)))
    len))

(defun fifo-head (fifo)
  "Return the number of elements in FIFO."
  (let ((dll (fifo-dllist fifo)))
    (and dll (dllist-value dll))))

(defun fifo-to-list (fifo)
  "Create a new FIFO queue containing LIST initially."
  (let ((dll (fifo-dllist fifo)))
    (when dll
      (cl-loop for i from 1 to (fifo-length fifo)
               for x = dll then (dllist-next x)
               while x
               for y = (dllist-value x)
               collect y))))

(ert-deftest fifo-push-test ()
  (let ((fifo (fifo-from-list '(1 2 3))))
    (fifo-push fifo 4)
    (should (equal '(1 2 3 4) (fifo-to-list fifo)))))

(ert-deftest fifo-pop-test ()
  (let ((fifo (fifo-from-list '(1 2 3))))
    (should (= 1 (fifo-pop fifo)))
    (should (equal '(2 3) (fifo-to-list fifo)))))

(provide 'fifo)

;;; fifo.el ends here
