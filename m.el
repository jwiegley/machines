;;; m --- Composible, asynchronous streaming machines -*- lexical-binding: t -*-

;;; Commentary:

;;; Code:

(require 'cl-lib)
(require 'cl-macs)
(require 'ts-queue)
(require 'generator)

(cl-defstruct flag
  "Simple representation of a \"flag\".
It should either be non-nil for active, or nil for inactive."
  name raised)

(defsubst m--debug (&rest args)
  (when ts-queue-debug (apply #'message args))
  (should (null (thread-last-error t))))

(defun m--drain-queue (input)
  "Drain the INPUT queue and return the list of its values."
  (m--debug "m--drain-queue..1 %S" (ts-queue-name input))
  (cl-loop for x = (ts-queue-pop input)
           until (ts-queue-at-eof x)
           collect x))

(defun m--connect-queues (input output &optional func stopped)
  "Drain the INPUT queue into the OUTPUT queue."
  (m--debug "m--connect-queues..1 %S %S %S"
            (ts-queue-name input)
            (ts-queue-name output) func)
  (cl-loop for x = (progn
                     (m--debug "m--connect-queues..2")
                     (let ((x (ts-queue-pop input)))
                       (m--debug "m--connect-queues..3 %S" x)
                       x))
           until   (progn
                     (m--debug "m--connect-queues..4 %S %S" x stopped)
                     (or (ts-queue-at-eof x)
                         (flag-raised stopped)))
           do      (progn
                     (m--debug "m--connect-queues..5")
                     (ts-queue-push output (funcall (or func #'identity) x))
                     (m--debug "m--connect-queues..6"))
           finally (progn
                     (m--debug "m--connect-queues..7")
                     (ts-queue-close output)
                     (m--debug "m--connect-queues..8")))
  (m--debug "m--connect-queues..done"))

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
  name input output thread (stopped (make-flag :name name)))

(defun m-join (machine)
  "Join on the thread for MACHINE."
  (m--debug "m-join..1 %S" (machine-name machine))
  (thread-join (machine-thread machine)))

(defun m-send (machine value)
  "Send the VALUE to the given MACHINE."
  (m--debug "m-send..1 %S %S" (machine-name machine) value)
  (ts-queue-push (machine-input machine) value))

(defun m-close (machine)
  "Close the MACHINE's input queue."
  (m--debug "m-close..1 %S" (machine-name machine))
  (ts-queue-close (machine-input machine))
  (m--debug "m-close..done %S" (machine-name machine)))

(defun m-await (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-await..1 %S" (machine-name machine))
  (ts-queue-pop (machine-output machine)))

(defun m-peek (machine)
  "Await the next results from the given MACHINE."
  (m--debug "m-peek..1 %S" (machine-name machine))
  (ts-queue-peek (machine-output machine)))

(defun m-drain (machine)
  "Drain the output of MACHINE into a list."
  (m--debug "m-drain..1 %S" (machine-name machine))
  (m--drain-queue (machine-output machine)))

(defun m-stop (machine)
  "Stop MACHINE, flushing any pending output first."
  (m--debug "m-stop..1 %S" (machine-name machine))
  (setf (flag-raised (machine-stopped machine)) t)
  (m--debug "m-stop..2 %S" (machine-name machine))
  (when (car (m-peek machine))
    (m--debug "m-stop..3 %S" (machine-name machine))
    (ignore (m-drain machine)))
  (m--debug "m-stop..4 %S" (machine-name machine))
  (m-join machine)
  (m--debug "m-stop..done %S" (machine-name machine)))

(defun m-source (machine)
  "A source is a MACHINE that expects no input."
  (m--debug "m-source..1 %S" (machine-name machine))
  (prog1
      machine
    (m--debug "m-source..2 %S" (machine-name machine))
    (m-close machine)
    (m--debug "m-source..3 %S" (machine-name machine))))

(defun m-sink (machine)
  "A sink is a MACHINE that produces no output."
  (m--debug "m-sink..1 %S" (machine-name machine))
  (prog1
      machine
    (m--debug "m-sink..2 %S" (machine-name machine))
    (ts-queue-close (machine-output machine))
    (m--debug "m-sink..3 %S" (machine-name machine))))

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
  (m--debug "m-output-closed-p..1 %s" (machine-name machine))
  (ts-queue-closed-p (machine-output machine)))

(cl-defun m-basic-machine
    (name func &key
          (no-input nil)
          (input-size 256)
          (input (unless no-input
                   (ts-queue-create :name (concat name " (input)")
                                    :size input-size)))
          (output-size 256)
          (output (ts-queue-create :name (concat name " (output)")
                                   :size output-size)))
  "Helper macro for creating basic machines.
NAME is the name of the machine.
FUNC is a function taking input and output ts-queues, and stopped flag.
NO-INPUT should be non-nil if this machine expects no input.
INPUT is the input ts-queue.
INPUT-SIZE is the input queue size, if NO-INPUT and INPUT are is nil.
OUTPUT is the output ts-queue.
OUTPUT-SIZE is the output queue size, if OUTPUT is nil."
  (declare (indent 1))
  (let ((stopped (make-flag :name name)))
    (make-machine
     :name name
     :input input
     :output output
     :thread
     (make-thread (apply-partially func input output stopped) name)
     :stopped stopped)))

(defun m-identity ()
  "The identity machine does nothing, just forwards input to output."
  (m-basic-machine "m-identity"
    #'(lambda (input output stopped)
        (m--connect-queues input output nil stopped))))

(defvar m--test-include
  ;; '(m-identity
  ;;   m-compose-identities)
  t
  )

(defmacro m--test (sym &rest body)
  (declare (indent 1))
  (unless (and (listp m--test-include)
               (not (memq sym m--test-include)))
    (let ((test-name (concat (symbol-name sym) "-test")))
      `(ert-deftest ,(intern test-name) ()
         (message ,(concat test-name "..."))
         (let ((threads (all-threads))
               (procs (process-list)))
           ,@body
           ;; (should (equal threads (all-threads)))
           ;; (should (equal procs (process-list)))
           )
         (m--debug ,(concat test-name "...done"))))))

(m--test m-identity
  (let ((m (m-identity)))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-compose (left right)
  "Compose the LEFT machine with the RIGHT.
This composes in the reverse order to mathematical composition: the left
machine acts on the inputs coming into the composed machine, and then
passes its outputs to the right machine.

This operation follows monoidal laws with respect to `m-identity',
making this a cartesian closed category of connected streaming machines."
  (let ((name (format "m-compose %s %s"
                      (machine-name left) (machine-name right))))
    (m-basic-machine name
      #'(lambda (input output stopped)
          (cl-loop
           for x = (progn
                     (m--debug "m-compose..3 %S" name)
                     (let ((x (m-await left)))
                       (m--debug "m-compose..4 %S %S" name x)
                       x))
           until   (progn
                     (m--debug "m-compose..5 %S %S %S" name x stopped)
                     (or (m-eof-p x)
                         (flag-raised stopped)))
           do      (progn
                     (m--debug "m-compose..6 %S" name)
                     (m-send right x)
                     (m--debug "m-compose..7 %S" name))
           finally (progn
                     (m--debug "m-compose..8 %S" name)
                     (m-close right)
                     (m--debug "m-compose..9 %S" name)
                     (m-stop left)
                     (m--debug "m-compose..10 %S" name))))
      :input (machine-input left)
      :output (machine-output right))))

(defalias 'm-connect 'm-compose)
(defalias 'm->> 'm-compose)

(m--test m-compose-identities
  (let ((m (m-compose (m-identity) (m-identity))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close m)
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (m-output-closed-p m))
    (m-stop m)))

(defun m-iterator (iter)
  (m-basic-machine "m-iterator"
    #'(lambda (_input output stopped)
        (m--debug "m-iterator..3 %S" (ts-queue-name output))
        (unwind-protect
            (condition-case e
                (progn
                  (m--debug "m-iterator..4 %S" (ts-queue-name output))
                  ;; jww (2025-06-28): This drains the iterator eagerly. Instead
                  ;; we would like to use a bounded queue.
                  (cl-loop
                   for x = (progn
                             (m--debug "m-iterator..5 %S" (ts-queue-name output))
                             (prog1
                                 (iter-next iter)
                               (m--debug "m-iterator..6 %S" (ts-queue-name output)))
                             )
                   until (progn
                           (m--debug "m-iterator..7 %S stopped %S"
                                     (ts-queue-name output) stopped)
                           (flag-raised stopped))
                   do (progn
                        (m--debug "m-iterator..8 %S %S" (ts-queue-name output) x)
                        (ts-queue-push output x)
                        (m--debug "m-iterator..9 %S %S" (ts-queue-name output) x)))
                  (m--debug "m-iterator..10"))
              (iter-end-of-sequence))
          (m--debug "m-iterator..11 %S" (ts-queue-name output))
          (ts-queue-close output)
          (m--debug "m-iterator..12 %S" (ts-queue-name output)))
        (m--debug "m-iterator..done %S" (ts-queue-name output)))
    :no-input t
    :output-size 16))

(m--test m-iterator
  (m--debug "m-iterator-test..1")
  (let ((m (m-iterator
            (funcall
             (iter-lambda ()
               (m--debug "m-iterator-test..2")
               (iter-yield 1)
               (m--debug "m-iterator-test..3")
               (iter-yield 2)
               (m--debug "m-iterator-test..4")
               (iter-yield 3)
               (m--debug "m-iterator-test..5")
               )))))
    (m--debug "m-iterator-test..6")
    (should (= 1 (m-await m)))
    (m--debug "m-iterator-test..7")
    (should (= 2 (m-await m)))
    (m--debug "m-iterator-test..8")
    (should (= 3 (m-await m)))
    (m--debug "m-iterator-test..9")
    (should (m-output-closed-p m))
    (m--debug "m-iterator-test..10")
    (m-join m)
    (m--debug "m-iterator-test..11")
    ))

(defun m-from-list-iter (xs)
  (m-iterator
   (funcall (iter-lambda ()
              (dolist (x xs)
                (m--debug "m-from-list..1 %S" x)
                (iter-yield x)
                (m--debug "m-from-list..2 %S" x)
                )
              (m--debug "m-from-list..done")
              ))))

(m--test m-from-list-iter
  (let ((m (m-from-list-iter '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(defun m-from-list (xs)
  (m-basic-machine "m-from-list"
    #'(lambda (_input output stopped)
        (m--debug "m-from-list..3")
        (catch 'done
          (dolist (x xs)
            (m--debug "m-from-list..4 %S" x)
            (if (flag-raised stopped)
                (progn
                  (m--debug "m-from-list..5 %S" x)
                  (throw 'done t))
              (m--debug "m-from-list..6 %S" x)
              (ts-queue-push output x))))
        (m--debug "m-from-list..7")
        (ts-queue-close output)
        (m--debug "m-from-list..done"))
    :no-input t
    :output-size 1))

(m--test m-from-list
  (let ((m (m-from-list '(1 2 3 4 5))))
    (should (= 1 (m-await m)))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (= 5 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(defalias 'm-to-list 'm-drain)

(iter-defun m-generator (machine)
  ;; We cannot use `m-for' here, because it runs afoul of Emacs's detection of
  ;; the use of `iter-yield' inside a generator.
  (cl-loop for x = (m-await machine)
           until (m-eof-p x)
           do (iter-yield x)
           finally (m-join machine)))

(m--test m-generator
  (let ((g (m-generator (m-from-list '(1 2 3)))))
    (should (= 1 (iter-next g)))
    (should (= 2 (iter-next g)))
    (should (= 3 (iter-next g)))
    (condition-case x
        (iter-next g)
      (iter-end-of-sequence
       (should (null (cdr x)))))))

(defun m-take (n machine)
  "Take at most N from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields that same
number of elements."
  (let ((name (format "m-take %s %S" n (machine-name machine))))
    (m-basic-machine name
      #'(lambda (input output stopped)
          (m--debug "m-take..3 %S" name)
          (cl-loop
           for i from 1 to n
           for x = (progn
                     (m--debug "m-take..4 %S %S %S" name i x)
                     (let ((y (m-await machine)))
                       (m--debug "m-take..5 %S %S %S %S" name i x y)
                       y))
           until   (progn
                     (m--debug "m-take..6 %S %S %S" name i x)
                     (or (m-eof-p x)
                         (flag-raised stopped)))
           do      (progn
                     (m--debug "m-take..7 %S %S %S" name i x)
                     (ts-queue-push output x)
                     (m--debug "m-take..8 %S %S %S" name i x))
           finally (progn
                     (m--debug "m-take..9 %S" name)
                     (ts-queue-close output)
                     (m--debug "m-take..10 %S" name)
                     (m-stop machine)
                     (m--debug "m-take..11 %S" name)
                     ))
          (m--debug "m-take..done %S" name)
          )
      :input (machine-input machine))))

(m--test m-take
  (let ((m (m-take 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-take-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-take-test..2")
    (should (= 2 (m-await m)))
    (m--debug "m-take-test..3")
    (should (m-output-closed-p m))
    (m--debug "m-take-test..4")
    (m-join m)
    (m--debug "m-take-test..5")
    ))

(defun m-head (machine)
  (m-take 1 machine))

(m--test m-head
  (let ((m (m-head (m-from-list '(1 2 3 4 5)))))
    (should (= 1 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(defun m-drop (n machine)
  "Drop the first N elements from the given MACHINE.
If MACHINE yields fewer than N elements, this machine yields none."
  (let ((name (format "m-drop %s %s" n (machine-name machine))))
    (m-basic-machine name
      #'(lambda (input output stopped)
          (m--debug "m-drop..3 %S" name)
          (let (ended)
            (cl-loop
             for i from 1 to n
             for x = (m-await machine)
             until (and (m-eof-p x) (setq ended t)))
            (m--debug "m-drop..4 %S" name)
            (unless ended
              (cl-loop
               for x = (progn
                         (m--debug "m-drop..5 %S" name)
                         (let ((x (m-await machine)))
                           (m--debug "m-drop..6 %S %S" name x)
                           x))
               until   (progn
                         (m--debug "m-drop..7 %S %S" name x)
                         (or (m-eof-p x)
                             (flag-raised stopped)))
               do      (progn
                         (m--debug "m-drop..8 %S %S" name x)
                         (ts-queue-push output x)
                         (m--debug "m-drop..9 %S %S" name x))
               finally (progn
                         (m--debug "m-drop..10 %S" name)
                         (ts-queue-close output)
                         (m--debug "m-drop..11 %S" name)))))
          (m--debug "m-drop..done %S" name)
          )
      :input (machine-input machine))))

(m--test m-drop
  (let ((m (m-drop 2 (m-from-list '(1 2 3 4 5)))))
    (m--debug "m-drop-test..1")
    (should (= 3 (m-await m)))
    (m--debug "m-drop-test..2")
    (should (= 4 (m-await m)))
    (m--debug "m-drop-test..3")
    (should (= 5 (m-await m)))
    (m--debug "m-drop-test..4")
    (should (m-output-closed-p m))))

(iter-defun m--iter-fix (func start)
  "The fixpoint combinator, implemented as an iterator.
Note that this does not stop when f x = x, because Emacs Lisp may yet
have side-effects in the remaining calls. It is up to the caller to
decide whether two of the same answer in a row indicates completion."
  (cl-loop for x = start then (funcall func x)
           ;; until (ts-queue-closed-p input)
           do (iter-yield x)))

(defun m-fix (func start)
  (m-basic-machine (format "m-fix %S" func)
    #'(lambda (_input output stopped)
        (m--debug "m-fix..3 %S" func)
        (cl-loop
         for x = start
         then (progn
                (m--debug "m-fix..4 %S %S" func x)
                (let ((y (funcall func x)))
                  (m--debug "m-fix..5 %S %S %S" func x y)
                  y))
         until (progn
                 (m--debug "m-fix..6 %S %S" func stopped)
                 (flag-raised stopped))
         do (progn
              (m--debug "m-fix..7 %S %S" func x)
              (ts-queue-push output x)
              (m--debug "m-fix..8 %S %S" func x)
              ))
        (m--debug "m-fix..9 %S" func)
        (ts-queue-close output)
        (m--debug "m-fix..done %S" func)
        )
    :no-input t
    :output-size 1))

(defun m-fibonacci ()
  "Return a Fibonacci series machine."
  (let ((prev-prev 0))
    (m-fix #'(lambda (prev)
               (prog1
                   (+ prev prev-prev)
                 (setq prev-prev prev)))
           1)))

(m--test m-fibonacci
  (let ((m (m-take 6 (m-fibonacci))))
    (m--debug "m-fibonacci-test..1")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test..2")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test..3")
    (should (= 2 (m-await m)))
    (m--debug "m-fibonacci-test..4")
    (should (= 3 (m-await m)))
    (m--debug "m-fibonacci-test..5")
    (should (= 5 (m-await m)))
    (m--debug "m-fibonacci-test..6")
    (should (= 8 (m-await m)))
    (m--debug "m-fibonacci-test..7")
    (should (m-output-closed-p m))
    (m--debug "m-fibonacci-test..8")
    (m-join m)
    (m--debug "m-fibonacci-test..9")
    ))

(defun m-fibonacci-iter ()
  "Return a Fibonacci series machine."
  (m-iterator
   (let ((prev-prev 0))
     (m--iter-fix #'(lambda (prev)
                      (prog1
                          (+ prev prev-prev)
                        (setq prev-prev prev)))
                  1))))

(m--test m-fibonacci-test
  (let ((m (m-take 6 (m-fibonacci-iter))))
    (m--debug "m-fibonacci-test-iter..1")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test-iter..2")
    (should (= 1 (m-await m)))
    (m--debug "m-fibonacci-test-iter..3")
    (should (= 2 (m-await m)))
    (m--debug "m-fibonacci-test-iter..4")
    (should (= 3 (m-await m)))
    (m--debug "m-fibonacci-test-iter..5")
    (should (= 5 (m-await m)))
    (m--debug "m-fibonacci-test-iter..6")
    (should (= 8 (m-await m)))
    (m--debug "m-fibonacci-test-iter..7")
    (should (m-output-closed-p m))
    (m--debug "m-fibonacci-test-iter..8")
    (m-join m)
    (m--debug "m-fibonacci-test-iter..9")
    ))

(defun m-series (left right)
  "Like `m-compose', but RIGHT is not sent input until LEFT is finished.")

(defun m-mapreduce (reduction &rest machines))

(defun m-concat (machines))

(defun m-unfold (func seed))

(defun m-for (machine func)
  "For every output of MACHINE, call FUNC for side-effects."
  (declare (indent 1))
  (cl-loop for x = (m-await machine)
           until (m-eof-p x)
           do (funcall func x)
           finally (m-join machine)))

(m--test m-for
  (m-for (m-from-list '(1 2 3))
    #'(lambda (x)
        (should (>= x 1))
        (should (<= x 3)))))

(defun m-map (func machine)
  (let ((name (format "m-map %s" (machine-name machine))))
    (m-basic-machine name
      #'(lambda (input output stopped)
          (m--debug "m-map..1 %S" name)
          (m--connect-queues (machine-output machine) output func stopped)
          (m--debug "m-map..2 %S" name)
          (m-stop machine)
          (m--debug "m-map..done %S" name)
          )
      :input (machine-input machine))))

(m--test m-map
  (let ((m (m-map #'1+ (m-from-list '(1 2 3)))))
    (should (= 2 (m-await m)))
    (should (= 3 (m-await m)))
    (should (= 4 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

;;; Example machines

(cl-defun m-funcall (func &key (combine #'identity))
  "Turn the function FUNC into a machine.
Since machine might receive their input piece-wise, the caller must
specify a function to COMBINE a list of input into a final input for
FUNC."
  (m-basic-machine "m-funcall"
    #'(lambda (input output _stopped)
        (thread-last
          input
          m--drain-queue
          (funcall combine)
          (funcall func)
          (ts-queue-push output))
        (ts-queue-close output))))

(m--test m-funcall
  (let ((m (m-funcall #'+ :combine (apply-partially #'cl-reduce #'+))))
    (m-send m 1)
    (m-send m 2)
    (m-send m 3)
    (m-close m)
    (should (= 6 (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(defun m-process (program &rest program-args)
  "Create a machine from a process. See `start-process' for details.
The PROGRAM and PROGRAM-ARGS are used to start the process."
  (let ((name (format "m-process %s" program)))
    (m-basic-machine name
      #'(lambda (input output stopped)
          (m--debug "m-process..3 %s" name)
          (let* (completed
                 (proc
                  (make-process
                   :name "m-process"
                   :command (cons program program-args)
                   :connection-type 'pipe
                   :filter #'(lambda (_proc x)
                               (m--debug "m-process..4 %s %S" name x)
                               (ts-queue-push output x)
                               (m--debug "m-process..5 %s" name)
                               )
                   :sentinel #'(lambda (_proc event)
                                 (m--debug "m-process..6 %s %S" name event)
                                 (ts-queue-close output)
                                 (m--debug "m-process..7 %s" name)
                                 (setq completed t)))))

            (m--debug "m-process..8 %s" name)
            (cl-loop
             for str = (progn
                         (m--debug "m-process..9 %s" name)
                         (let ((x (ts-queue-pop input)))
                           (m--debug "m-process..10 %s %S" name x)
                           x))
             until     (progn
                         (m--debug "m-process..11 %s %S" name str)
                         (let ((x (m-eof-p str)))
                           (m--debug "m-process..12 %s %S" name x)
                           x))
             do        (progn
                         (m--debug "m-process..13 %s %S" name str)
                         (process-send-string proc str))
             finally   (progn
                         (m--debug "m-process..14 %s" name)
                         (process-send-eof proc)))

            (m--debug "m-process..15 %s" name)
            (while (not completed)
              (m--debug "m-process..16 %s" name)
              (thread-yield)
              (m--debug "m-process..17 %s" name)
              (accept-process-output proc nil 100)
              (m--debug "m-process..18 %s" name)
              )

            (m--debug "m-process..done %s" name)
            )))))

(m--test m-process
  (let ((m (m-process "cat")))
    (m-send m "Hello\n")
    (m-close m)
    (should (string= "Hello\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(m--test m-process-drain
  (let ((m (m-process "echo" "Hello there")))
    (thread-last
      m
      (m-source)
      (m-drain)
      (mapconcat #'identity)
      (string= "Hello there\n")
      should)
    (m-join m)))

(m--test m-process-compose
  (let ((m (m-compose (m-process "grep" "--line-buffered" "foo")
                      (m-process "wc" "-l"))))
    (m-send m "foo\n")
    (m-send m "bar\n")
    (m-send m "foo\n")
    (m-close m)
    (should (string= "2\n" (m-await m)))
    (should (m-output-closed-p m))
    (m-join m)))

(provide 'm)

;;; m.el ends here
