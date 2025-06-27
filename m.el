;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'queue)

(cl-defstruct machine
  "Machines map INPUTS to OUTPUTS by executing code in THREAD.
Note that INPUTS may be either a single queue or a vector of queues, it
all depends on the machine and how it draws its inputs. Likewise,
outputs may be a single queue of cons cells, for example, or a pair of
queues of car/cdr values, depending on the nature of the asynchronicity
desired.

THREAD should read from its inputs until it receives an `:m--eof` token
on each of them, while writing to its outputs until it is finished and
writes `:m--eof` to each of them. At this point the thread should exit."
  inputs outputs thread)

(cl-defun m-funcall (func &key combine)
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of inputs into a final input for
FUNC."
  (let ((input (queue-create))
        (output (queue-create)))
    (make-machine
     :inputs input
     :thread output
     :thread (make-thread
              #'(lambda ()
                  ;; jww (2025-06-27): Need a way for machines to indicate
                  ;; when they are done operating. This mechanism here of
                  ;; pushing a special token onto the queue is not great.
                  (let ((xs (cl-loop for x = (queue-pop input)
                                     unless (eq x :m--eof)
                                     collect x)))
                    (queue-push output (funcall func (funcall combine xs)))
                    (queue-push output :m--eof)))))))

;; (m-funcall #'+ :combine #'-sum)

(defun m--normalize (x)
  "Return X as a singleton vector if it is not already a vector."
  (if (vectorp x) x [x]))

(defun m-send (machine arguments)
  "Send the ARGUMENTS to the given MACHINE.
ARGUMENTS must be a vector of matching length if the MACHINE takes a
vector of inputs."
  (let ((inputs (m--normalize (machine-inputs machine)))
        (args (m--normalize arguments)))
    (if (= (seq-length inputs) (seq-length args))
        (seq-mapn #'queue-push inputs args)
      (error "Input(s) and argument(s) must be of equal length"))))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (let ((outputs (m--normalize (machine-outputs machine))))
    (seq-into (seq-map #'queue-pop outputs) 'vector)))

(defun m-identity ()
  "The machine does nothing, and simply forwards inputs to outputs."
  (let ((input (queue-create))
        (output (queue-create)))
    (make-machine
     :inputs input
     :thread output
     :thread (make-thread
              #'(lambda ()
                  (cl-loop for x = (queue-pop input)
                           unless (eq x :m--eof)
                           do (queue-push output x)
                           finally (queue-push output :m--eof)))))))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This operation follows monoidal laws with respect to m-identity."
  (make-machine
   :inputs (machine-inputs left)
   :thread (machine-outputs right)
   :thread (make-thread
            #'(lambda ()
                (cl-loop for xs = (m-await left)
                         do (m-send right xs))))))

(provide 'm)

;;; m.el ends here
