(in-package #:com.metabang.trivial-timeout)

(define-condition timeout-error (error) ()
  (:report (lambda (c s)
             (declare (ignore c))
             (format s "Process timeout")))
  (:documentation "An error signaled when the duration specified in 
the [with-timeout][] is exceeded."))

#+allegro
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  `(mp:with-timeout (,seconds-symbol (error 'timeout-error)) 
     (,doit-symbol)))


#+(and sbcl (not sb-thread))
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  (let ((glabel (gensym "label-"))
        (gused-timer? (gensym "used-timer-")))
    `(let ((,gused-timer? nil))
       (catch ',glabel
         (sb-ext:schedule-timer
          (sb-ext:make-timer (lambda ()
                               (setf ,gused-timer? t)
                               (throw ',glabel nil)))
          ,seconds-symbol)
         (,doit-symbol))
       (when ,gused-timer?
         (error 'timeout-error)))))

#+(and sbcl sb-thread)
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  `(handler-case 
       (sb-ext:with-timeout ,seconds-symbol (,doit-symbol))
     (sb-ext::timeout (c)
       (declare (ignore c))
       (error 'timeout-error))))

#+cmu
;;; surely wrong
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  `(handler-case 
       (mp:with-timeout (seconds-symbol) (,doit-symbol))
     (sb-ext::timeout (c)
       (declare (ignore c))
       (error 'timeout-error))))

#+(or digitool openmcl ccl)
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  (let ((checker-process (format nil "Checker ~S" (gensym)))
        (waiting-process (format nil "Waiter ~S" (gensym)))
        (result (gensym))
        (process (gensym)))
    `(let* ((,result nil)
            (,process (ccl:process-run-function 
                       ,checker-process
                       (lambda ()
                         (setf ,result (multiple-value-list (,doit-symbol))))))) 
       (ccl:process-wait-with-timeout
        ,waiting-process
        (* ,seconds-symbol #+(or openmcl ccl)
                           ccl:*ticks-per-second* #+digitool 60)
        (lambda ()
          (not (ccl::process-active-p ,process)))) 
       (when (ccl::process-active-p ,process)
         (ccl:process-kill ,process)
         (cerror "Timeout" 'timeout-error))
       (values-list ,result))))

#+(or digitool openmcl ccl)
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  (let ((gsemaphore (gensym "semaphore"))
	(gresult (gensym "result"))
	(gprocess (gensym "process")))
    `(let* ((,gsemaphore (ccl:make-semaphore))
            (,gresult)
            (,gprocess
              (ccl:process-run-function
               ,(format nil "Timed Process ~S" gprocess)
               (lambda ()
                 (setf ,gresult (multiple-value-list (,doit-symbol)))
                 (ccl:signal-semaphore ,gsemaphore)))))
       (cond ((ccl:timed-wait-on-semaphore ,gsemaphore ,seconds-symbol)
              (values-list ,gresult))
             (t
              (ccl:process-kill ,gprocess)
              (error 'timeout-error))))))

#+lispworks
(defun generate-platform-specific-code (seconds-symbol doit-symbol)
  ;; For LispWorks, we'll start a separate "guard" thread which
  ;; will interrupt the current thread when timeout will happen.
  ;; 
  ;; If a computation finishes before timeout, it terminates "guard"
  ;; thread.
  (let ((g-main-process (gensym "main-process-"))
        (g-guard-process (gensym "guard-process-")))
    `(let* ((,g-main-process (mp:get-current-process))
            (,g-guard-process
              (mp:process-run-function
               "WITH-TIMEOUT" ()
               (lambda ()
                 (mp:process-wait-with-timeout "WITH-TIMEOUT" ,seconds-symbol)

                 ;; body didn't return yet
                 (mp:process-interrupt ,g-main-process
                                       (lambda ()
                                         (cerror "Timeout" 'timeout-error)))))))
       (unwind-protect
            (,doit-symbol)
         (mp:process-terminate ,g-guard-process)))))

(unless (let ((symbol
                (find-symbol (symbol-name '#:generate-platform-specific-code)
                             '#:com.metabang.trivial-timeout)))
          (and symbol (fboundp symbol)))
  (defun generate-platform-specific-code (seconds-symbol doit-symbol)
    (declare (ignore seconds-symbol))
    `(,doit-symbol)))

(defmacro with-timeout ((seconds) &body body)
  "Execute `body` for no more than `seconds` time. 

If `seconds` is exceeded, then a [timeout-error][] will be signaled. 

If `seconds` is nil, then the body will be run normally until it completes
or is interrupted."
  (build-with-timeout seconds body))

(defun build-with-timeout (seconds body)
  (let ((gseconds (gensym "seconds-"))
        (gdoit (gensym "doit-")))
    `(let ((,gseconds ,seconds))
       (flet ((,gdoit ()
                (progn ,@body)))
         (cond (,gseconds
                ,(generate-platform-specific-code gseconds gdoit))
               (t
                (,gdoit)))))))
