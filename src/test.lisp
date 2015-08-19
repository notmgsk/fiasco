;;; -*- mode: Lisp -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :fiasco)

(defclass test (testable)
  ((package :initform nil :accessor package-of :initarg :package)
   (lambda-list :initform nil :accessor lambda-list-of :initarg :lambda-list)
   (compile-before-run :initform t :accessor compile-before-run-p
                       :initarg :compile-before-run :type boolean)
   (declarations :initform nil :accessor declarations-of
                 :initarg :declarations)
   (documentation :initform nil :accessor documentation-of
                  :initarg :documentation)
   (body :initform nil :accessor body-of
         :initarg :body)))

(defun ensure-test (name &rest args &key &allow-other-keys)
  (let ((test (find-test name :otherwise nil)))
    (if test
        (apply #'reinitialize-instance test args)
        (apply #'make-instance 'test :name name args))))

(defun call-with-test-handlers (function)
  ;; NOTE: the order of the bindings in this handler-bind is important
  (handler-bind
      ((failed-assertion
        (lambda (c)
          (push c (failures-of *context*))
          (unless *debug-on-assertion-failure*
            (continue))))
       (serious-condition
        (lambda (c)
          (record-failure 'unexpected-error :error c)
          (return-from call-with-test-handlers))))
    (funcall function)))

(defun run-test-body-in-handlers (test function)
  (declare (type test test)
           (type function function))
  (signal 'test-started :test test)
  (labels ((run-test-body ()
             (call-with-test-handlers
              (lambda ()
                (restart-case
                    (let* ((*package* (package-of test))
                           (*readtable* (copy-readtable))
                           (start-time (get-internal-run-time)))
                      (multiple-value-prog1
                          (funcall function)
                        (setf (internal-realtime-spent-with-test-of *context*)
                              (- (get-internal-run-time) start-time))))
                  (continue ()
                    :report (lambda (stream)
                              (format stream "~
~@<Skip the rest of the test ~S and continue by ~
returning (values)~@:>" (name-of test)))
                    (values))
                  (retest ()
                    :report (lambda (stream)
                              (format stream "~@<Rerun the test ~S~@:>"
                                      (name-of test)))
                    ;; Make a new pristine *CONTEXT* binding
                    ;;
                    (setf *context*
                          (make-instance 'context
                                         :test (test-of *context*)
                                         :test-arguments (test-arguments-of *context*)
                                         :parent-context (parent-context-of *context*)))
                    (return-from run-test-body (run-test-body))))))))
    (run-test-body)))

(defvar *run-test-function* #'run-test-body-in-handlers)

(defmacro deftest (&whole whole name args &body body)
  (multiple-value-bind (remaining-forms declarations documentation)
      (parse-body body :documentation t :whole whole)
    (destructuring-bind (name &rest test-args &key (in nil in-provided?)
                                                   timeout &allow-other-keys)
        (ensure-list name)
      (remove-from-plistf test-args :in)
      (with-unique-names (body-sym)
        `(progn
           (eval-when (:load-toplevel :execute)
             (ensure-test ',name
                          :package ,*package*
                          :lambda-list ',args
                          :declarations ',declarations
                          :documentation ',documentation
                          :body ',remaining-forms
                          ,@(when in-provided?
                              `(:in (find-test ',in)))
                          ,@test-args))
           (defun ,name ,args
             ,@(when documentation (list documentation))
             ,@declarations
             (let* ((*current-test* (find-test ',name))
                    (*previous-context* (and (boundp '*context*)
                                             *context*))
                    (*context* nil))
               (labels ((,name () ,@remaining-forms) ; for clarity in debugger
                        (,body-sym ()
                          (setq *context*
                                (make-instance
                                 'context
                                 :test *current-test*
                                 :test-arguments ,(lambda-list-to-value-list-expression args)
                                 :parent-context *previous-context*))
                          (handler-bind
                              ((test-assertion
                                 (lambda (a) (push a (assertions-of *context*))))
                               (test-started
                                 (lambda (c) (declare (ignore c)))))
                            (when ,timeout
                              (error "TODO: timeouts are not implemented yet in Fiasco."))
                            (funcall *run-test-function* *current-test* #',name))))
                 (if *previous-context*
                     (,body-sym)
                     (with-toplevel-restarts
                         (let ((*standard-output* (eval *test-run-standard-output*))
                               (*debug-on-assertion-failure* *debug-on-assertion-failure*)
                               (*debug-on-unexpected-error*  *debug-on-unexpected-error*)
                               (*print-test-run-progress*    *print-test-run-progress*)
                               (*progress-char-count*        *progress-char-count*))
                           (let ((results (multiple-value-list (,body-sym))))
                             (multiple-value-prog1
                                 (values-list
                                  (append results
                                          (list *context*)))
                               (when *print-test-run-progress*
                                 (terpri *debug-io*))
                               (push *context* *test-result-history*)
                               (setq *last-test-result* *context*))))))))))))))
