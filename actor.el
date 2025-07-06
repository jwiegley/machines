;;; actor.el --- Actor model in Emacs Lisp, using EIEIO -*- lexical-binding: t -*-

;;; Commentary:

;; This code is taken from
;; https://github.com/naveensundarg/Common-Lisp-Actors/blob/master/actors.lisp
;; or
;; https://github.com/DruidGreeneyes/cl-actors/blob/master/actors.lisp

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'ts-queue)

;; ----------------------------------------------------------------------------
(defclass actor ()
  ((name :initarg :name
         :initform (error ":name must be specified")
         :accessor name
         :documentation "Hold the name of actor")
   (behavior :initarg :behavior
             :initform (error ":behav must be specified")
             :accessor behavior
             :documentation "Behavior")
   (messages :initform '()
             :accessor messages
             :documentation "Message stream sent to actor")
   thread))

;; ----------------------------------------------------------------------------
(cl-defmethod initialize-instance :after ((self actor) &optional slots)
  "Uses the main functiona name to create a thread."
  (with-slots (name thread messages) self
    (setf messages (ts-queue-create))
    (setf thread (make-thread #'(lambda() (main self)) name))))

(cl-defmethod send ((self actor) &rest xs)
  "Creates a message sending thread which
1. Holds lock to the message (queue)
2. Appends messages (queue) with incoming message
3. Releases lock
4. Notifies the waiting thread that there is a message"
  (with-slots (messages) self
    (make-thread #'(lambda () (ts-queue-push messages xs)))
    (cl-values)))

(cl-defmethod close-actor ((self actor))
  (with-slots (messages) self
    (make-thread #'(lambda () (ts-queue-close messages)))
    (cl-values)))

(cl-defmethod cancel-actor ((self actor))
  "Cancels the actor thread, stopping it immediately with a signal."
  (with-slots (thread) self
    (thread-signal thread 'canceled nil)))

(cl-defmethod stop-actor ((self actor))
  "Stops the actor thread by sending it a closed input signal."
  (close-actor self)
  (with-slots (thread) self
    (thread-join thread)))

(cl-defmethod get-thread ((self actor))
  "Returns the handle of a thread"
  (with-slots (thread) self thread))

;; ----------------------------------------------------------------------------
(cl-defmethod main ((self actor))
  "The main which is started as a thread from the constructor I think that
this should be more of an internal function than a method (experiment
with funcallable-standard-class)."
  (with-slots ((behav behavior) messages) self
    (cl-loop while behav
             for x = (progn
                       (thread-yield)
                       (ts-queue-pop messages))
             until (ts-queue-at-eof x)
             do (setf behav (apply behav x)))))

(cl-defmacro actor-lambda (state vars &body body)
  "Create a behavior that can be attached to any actor."
  (declare (indent 2))
  `(let ,state
     (cl-labels ((me ,(append vars '(&key self (next #'me next-supplied-p)))
                   (if next-supplied-p
                       (setf next (curry next :self self)))
                   ,@body))
       #'me)))

(cl-defmacro defactor (name state vars &body body)
  "Macro for creating actors with the behavior specified by body."
  (declare (indent 3))
  `(cl-defun ,name (&key (self) ,@state)
     (cl-labels ((me ,(append vars '(&key (next #'me next-supplied-p)))
                   (if next-supplied-p
                       (setf next (curry next :self self)))
                   ,@body))
       (setf self (make-actor #'me ,(symbol-name name)))
       self)))

(defun make-actor (behav name)
  (make-instance 'actor
                 :name (cl-concatenate 'string "Actor: " name)
                 :behavior behav))

(defun sink (&rest _args) #'sink)

(defun curry (f &rest args)
  #'(lambda (&rest rem) (apply f (append rem args))))

(defactor printer1 () (x)
  (message "printer1: %S" x)
  next)

(defactor printer2 () (x)
  (message "printer2: %S" x)
  next)

(defun actor-test ()
  (let ((my-actor1 (printer1))
        (my-actor2 (printer2)))
    (when-let ((err (thread-last-error t)))
      (message "step 1: %S" err))
    (send my-actor1 1)
    (when-let ((err (thread-last-error t)))
      (message "step 2: %S" err))
    (let ((me2 (actor-lambda () (x)
                 (message "me2...")
                 (send my-actor2 (* x 10))
                 next)))
      (send my-actor1 2 :next me2))
    (when-let ((err (thread-last-error t)))
      (message "step 3: %S" err))
    (send my-actor1 3)
    (when-let ((err (thread-last-error t)))
      (message "step 4: %S" err))
    (send my-actor1 4)
    (when-let ((err (thread-last-error t)))
      (message "step 5: %S" err))
    (send my-actor1 5)
    (when-let ((err (thread-last-error t)))
      (message "step 6: %S" err))
    (let ((result1 (stop-actor my-actor1))
          (result2 (stop-actor my-actor2)))
      (message "Actor1 stopped: %S" result1)
      (message "Actor2 stopped: %S" result2)
      (cons result1 result2))))

(provide 'actor)

;;; actor.el ends here
