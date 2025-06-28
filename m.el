;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'ts-queue)

(defsubst m--debug (&rest args)
  (when ts-queue-debug (apply #'message args)))

(defun m--drain-queue (input)
  "Drain the INPUT queue and return the list of its values."
  (m--debug "m--drain-queue..1 %S" input)
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           collect x))

(defun m--connect-queues (input output)
  "Drain the INPUT queue into the OUTPUT queue."
  (m--debug "m--connect-queues..1 %S %S" input output)
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           do (ts-queue-push output x)
           finally (ts-queue-close output)))

(cl-defstruct (machine (:copier nil))
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
  name input output thread)

(defun m-join (machine)
  "Join on the thread for MACHINE."
  (thread-join (machine-thread machine)))

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (m--debug "m-send..1 %S %S" machine value)
  (ts-queue-push (machine-input machine) value))

(defun m-close-input (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-close-input..1 %S" machine)
  (ts-queue-close (machine-input machine)))

(defun m-close-output (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-close-output..1 %S" machine)
  (ts-queue-close (machine-output machine)))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-await..1 %S" machine)
  (ts-queue-pop (machine-output machine)))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-peek..1 %S" machine)
  (ts-queue-peek (machine-output machine)))

(defun m-drain (machine)
  "Drain the output of MACHINE into a list."
  (m--debug "m-drain..1 %S" machine)
  (m--drain-queue (machine-output machine)))

(defun m-source (machine)
  "A source is a MACHINE that expects no input."
  (m--debug "m-source..1 %S" machine)
  (prog1
      machine
    (m-close-input machine)))

(defun m-sink (machine)
  "A sink is a MACHINE that produces no output."
  (m--debug "m-sink..1 %S" machine)
  (prog1
      machine
    (m-close-output machine)))

(defun m-fanout (machine1 machine2 &rest machines)
  "Create a machine that sends its input to all the machines.
The results are transmitted with a tag to indicate which machine they
originated from:
  (1 . value)
  (0 . value)
  (1 . value)
")

(defun m-fanin (machine1 machine2 &rest machines))

(defalias 'm-eof-p 'ts-queue-at-eof)

(defun m-output-closed-p (machine)
  "Return non-nil if the MACHINE's output queue has been closed.
This should only ever be called once, and will block until it sees the
closure token, so only call this in conditions where you know exactly
when to expect that the output is closed. Generally this is only useful
for testing."
  (m--debug "m-output-closed-p..1 %S" machine)
  (ts-queue-closed-p (machine-output machine)))

(defun m--parts (name)
  (list name
        (ts-queue-create :name (concat name " (input)"))
        (ts-queue-create :name (concat name " (output)"))))

(defsubst m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m--debug "m-identity..1")
  (cl-destructuring-bind (name input output)
      (m--parts "m-identity")
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda () (m--connect-queues input output))
      name))))

(ert-deftest m-identity-test ()
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)
    (should (null (thread-last-error t)))))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This composes in the reverse order to mathematical composition: the left
machine acts on the inputs coming into the composed machine, and then
passes its outputs to the right machine.

This operation follows monoidal laws with respect to m-identity, making
this a cartesian closed category of connected streaming machines."
  (let ((name (format "m-compose %s %s"
                      (machine-name left) (machine-name right))))
    (make-machine
     :name name
     :input (machine-input left)
     :output (machine-output right)
     :thread (make-thread
              #'(lambda ()
                  (cl-loop for x = (m-await left)
                           until (m-eof-p x)
                           do (m-send right x)
                           finally (m-close-input right)))
              name))))

(defalias 'm-connect 'm-compose)
(defalias 'm->> 'm-compose)

(ert-deftest m-compose-identities-test ()
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)
    (should (null (thread-last-error t)))))

(defun m-from-list (xs)
  (m--debug "m-from-list..1")
  (let* ((name "m-from-list")
         (output (ts-queue-create :name (concat name " (output)"))))
    (m--debug "m-from-list..2")
    (make-machine
     :name name
     :input nil
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-from-list..3")
          (dolist (x xs)
            (m--debug "m-from-list..4 %S" x)
            (ts-queue-push output x))
          (m--debug "m-from-list..5")
          (ts-queue-close output)
          (m--debug "m-from-list..6")
          )
      name))))

(ert-deftest m-from-list-test ()
  (let ((m (m-from-list '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  (should (null (thread-last-error t))))

(defalias 'm-to-list 'm-drain)

(defun m-map (func machine)
  (m--debug "m-map..1 %S %s" func (machine-name machine))
  (let* ((name (format "m-map %s" (machine-name machine)))
         (output (ts-queue-create :name (concat name " (output)"))))
    (m--debug "m-map..2")
    (make-machine
     :name name
     :input (machine-input machine)
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-map..3")
          (cl-loop for x = (progn
                             (m--debug "m-map..4")
                             (m-await machine))
                   until   (progn
                             (m--debug "m-map..5 %S" x)
                             (m-eof-p x))
                   do      (progn
                             (m--debug "m-map..6 %S %S" func x)
                             (let ((arg (funcall func x)))
                               (m--debug "m-map..7 %S" arg)
                               (ts-queue-push output arg)
                               (m--debug "m-map..8")))
                   finally (progn
                             (m--debug "m-map..9")
                             (ts-queue-close output)
                             (m--debug "m-map..10")
                             ))
          (m--debug "m-map..11")
          )
      name))))

(ert-deftest m-map-test ()
  (let ((m (m-map #'1+ (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  (should (null (thread-last-error t))))

;;; Example machines

(cl-defun m-funcall (func &key (combine #'identity))
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (cl-destructuring-bind (name input output)
      (m--parts "m-funcall")
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (thread-last
            input
            m--drain-queue
            (funcall combine)
            (funcall func)
            (ts-queue-push output))
          (ts-queue-close output))
      name))))

(ert-deftest m-funcall-test ()
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close-input m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)
    (should (null (thread-last-error t)))))

(defun m-process (program &rest program-args)
  "Create a machine from a process. See `start-process' for details.
The PROGRAM and PROGRAM-ARGS are used to start the process."
  (m--debug "m-process..1 %S %S" program program-args)
  (cl-destructuring-bind (name input output)
      (m--parts (format "m-process %s" program))
    (m--debug "m-process..2 %S %S" input output)
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread
      #'(lambda ()
          (m--debug "m-process..3")
          (let* (completed
                 (proc
                  (make-process
                   :name "m-process"
                   :command (cons program program-args)
                   :connection-type 'pipe
                   :filter #'(lambda (_proc x)
                               (m--debug "m-process..4 %S" x)
                               (ts-queue-push output x)
                               (m--debug "m-process..5")
                               )
                   :sentinel #'(lambda (_proc event)
                                 (m--debug "m-process..6 %S" event)
                                 (ts-queue-close output)
                                 (m--debug "m-process..7")
                                 (setq completed t)))))

            (m--debug "m-process..8")
            (cl-loop for str = (progn
                                 (m--debug "m-process..9 %S")
                                 (let ((x (ts-queue-pop input)))
                                   (m--debug "m-process..10 %S" x)
                                   x))
                     until     (progn
                                 (m--debug "m-process..11 %S" str)
                                 (let ((x (m-eof-p str)))
                                   (m--debug "m-process..12 %S" x)
                                   x))
                     do        (progn
                                 (m--debug "m-process..13 %S" str)
                                 (process-send-string proc str))
                     finally   (progn
                                 (m--debug "m-process..14")
                                 (process-send-eof proc)))

            (m--debug "m-process..15")
            (while (not completed)
              (m--debug "m-process..16 %S")
              (thread-yield)
              (m--debug "m-process..17 %S")
              (accept-process-output proc nil 100)
              (m--debug "m-process..18 %S")
              )

            (m--debug "m-process..19 %S")
            ))
      name))))

(ert-deftest m-process-test ()
  (let ((m (m-process "cat")))
    (m-send m "Hello\n")
    (m-close-input m)
    (should (string= "Hello\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  (should (null (thread-last-error t))))

(ert-deftest m-process-drain-test ()
  (let ((m (m-process "echo" "Hello there")))
    (thread-last
      m
      (m-source)
      (m-drain)
      (mapconcat #'identity)
      (string= "Hello there\n")
      should)
    (m-join m))
  (should (null (thread-last-error t))))

(ert-deftest m-process-compose-test ()
  (setq ts-queue-debug nil)
  (let ((m (m-compose (m-process "grep" "--line-buffered" "foo")
                      (m-process "wc" "-l"))))
    (m-send m "foo\n")
    (m-send m "bar\n")
    (m-send m "foo\n")
    (m-close-input m)
    (should (string= "2\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m))
  (should (null (thread-last-error t))))

(provide 'm)

;;; m.el ends here
