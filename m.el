;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'ts-queue)

(cl-defstruct
    (machine
     (:copier nil)
     (:constructor nil)
     (:constructor
      m-create
      (&key (input (ts-queue-create))
            (output (ts-queue-create))
            (thread
             (make-thread
              #'(lambda ()
                  (cl-loop for x = (ts-queue-pop input)
                           until (ts-queue-at-eof x)
                           do (ts-queue-push output x)
                           finally (ts-queue-close output))))))))
  "Machines map INPUT to OUTPUT by executing code in THREAD.
Note that INPUT may be either a single queue or a vector of queues, it
all depends on the machine and how it draws its input. Likewise,
output may be a single queue of cons cells, for example, or a pair of
queues of car/cdr values, depending on the nature of the asynchronicity
desired.

THREAD should read from its input until the value receives yields true
when passed to `ts-queue-at-eof', while writing to its output until
finished, after which it should close the output queue using
`ts-queue-close'. At this point the thread should exit."
  input output thread)

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (ts-queue-push (machine-input machine) value))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (ts-queue-pop (machine-output machine)))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (ts-queue-peek (machine-output machine)))

(defun m-close-input (machine)
  "Close the MACHINE's input queue."
  (ts-queue-close (machine-input machine)))

(defun m-output-closed-p (machine)
  "Return non-nil if the MACHINE's output queue has been closed.
This should only ever be called once, and will block until it sees the
closure token, so only call this in conditions where you know exactly
when to expect that the output is closed. Generally this is only useful
for testing."
  (ts-queue-at-eof (m-await machine)))

(defsubst m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m-create))

(ert-deftest m-identity-test ()
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This operation follows monoidal laws with respect to m-identity."
  (m-create
   :input (machine-input left)
   :output (machine-output right)
   :thread (make-thread
            #'(lambda ()
                (cl-loop for xs = (m-await left)
                         do (m-send right xs))))))

(ert-deftest m-compose-identities-test ()
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))))

;;; Example machines

(cl-defun m-funcall (func &key combine)
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (let ((input (ts-queue-create))
        (output (ts-queue-create)))
    (m-create
     :input input
     :thread output
     :thread (make-thread
              #'(lambda ()
                  ;; jww (2025-06-27): Need a way for machines to indicate
                  ;; when they are done operating. This mechanism here of
                  ;; pushing a special token onto the queue is not great.
                  (let ((xs (cl-loop for x = (ts-queue-pop input)
                                     unless (eq x :m--eof)
                                     collect x)))
                    (ts-queue-push output (funcall func (funcall combine xs)))
                    (ts-queue-push output :m--eof)))))))

;; (m-funcall #'+ :combine #'-sum)

(provide 'm)

;;; m.el ends here
