

[2012.01.16] {Developing clusterbench, seeing indefinite MVar block failures}
-----------------------------------------------------------------------------

Here's the tail end of the run:

    .....
      + Executor on host granite.cs.indiana.edu invoking commands: ["mkdir -p ~/clusterbench/run_1/GHC721_A2M_qa__TRIALS3_THREADS01234_KEEPGOING1_SCHEDSTraceDirectSparks/working_copy","git clone ~/cluster_monad_par_launchpad ~/clusterbench/run_1/GHC721_A2M_qa__TRIALS3_THREADS01234_KEEPGOING1_SCHEDSTraceDirectSparks/working_copy","cd ~/clusterbench/run_1/GHC721_A2M_qa__TRIALS3_THREADS01234_KEEPGOING1_SCHEDSTraceDirectSparks/working_copy","git submodule init","git submodule update"]
      - Polling... wait, all nodes are busy, waiting 10 seconds...
     !! FAILED to lock remote machine granite.cs.indiana.edu, moving on...
      - launchConfigs: All launched, waiting for 8 outstanding jobs to complete or fail.
    clusterbench.exe: thread blocked indefinitely in an MVar operation

    [rrnewton@hulk ~/cluster_monad_par_launchpad/examples] (master)$ runInHandler/(String -> IO String): /dev/stdout: hClose: resource vanished (Broken pipe)
    benchmark: user error ((String -> IO String): exited with code 1)
    runInHandler/(String -> IO String): /dev/stdout: hClose: resource vanished (Broken pipe)
    benchmark: user error ((String -> IO String): exited with code 1)


The problem may have been this failed SSH from earlier:

    clusterbench.exe: user error (ssh coal.cs.indiana.edu 'cd ~/clusterbench/run_1/GHC74020111219_A256K_qa__TRIALS3_THREADS01234_KEEPGOING1_SCHEDSTraceDirectSparks/working_copy/examples && export GHC="ghc-7.4.0.20111219" && export TRIALS="3" && export THREADS="0 1 2 3 4" && export KEEPGOING="1" && export SCHEDS="Trace Direct Sparks" && export GHC_RTS="-A256K -qa -s" && export GHC_FLAGS="" && ghc-7.0.4 --make ./benchmark.hs && ./benchmark': exited with code 1)


[2012.01.22] {Debugging new parallel benchmark.hs}
--------------------------------------------------

My first strategy, spawning ALL compiles or ALL runs at once seemed to
work.  But now I'm seeing OCCASIONAL failures of the following sort
during compilation:

    benchmark.exe: ExitFailure 1

Ouch... after running this for a while I also see a lot of ZOMBIE
PROCESSES left behind.  Bash, ghc, and gcc ones.  Especially long gcc
ones like this:

     rrnewton       35763   0.0  0.0  2447544    396 s003  T     4:12AM   0:00.00 /usr/bin/i686-apple-darwin11-gcc-4.2.1 -m64 -fno-stack-protector -m64 -Wl,-no_compact_unwind ../Control/Monad/Par/Combinator.o ../Control/Monad/Par/Scheds/Trace.o queens.o ../Control/Monad/Par/Class.o ../Control/Monad/Par/Scheds/TraceInternal.o -L/Users/rrnewton/.cabal/lib/parallel-3.2.0.2/ghc-7.4.0.20111219 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/containers-0.4.2.1 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/deepseq-1.3.0.0 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/array-0.4.0.0 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/base-4.5.0.0 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/integer-gmp-0.4.0.0 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219/ghc-prim-0.2.0.0 -L/Users/rrnewton/opt//lib/ghc-7.4.0.20111219 /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc34897_0/ghc34897_0.o -lHSparallel-3.2.0.2 -lHScontainers-0.4.2.1 -lHSdeepseq-1.3.0.0 -lHSarray-0.4.0.0 -lHSbase-4.5.0.0 -liconv -lHSinteger-gmp-0.4.0.0 -lHSghc-prim-0.2.0.0 -lHSrts -lm -ldl -u _ghczmprim_GHCziTypes_Izh_static_info -u _ghczmprim_GHCziTypes_Czh_static_info -u _ghczmprim_GHCziTypes_Fzh_static_info -u _ghczmprim_GHCziTypes_Dzh_static_info -u _base_GHCziPtr_Ptr_static_info -u _base_GHCziWord_Wzh_static_info -u _base_GHCziInt_I8zh_static_info -u _base_GHCziInt_I16zh_static_info -u _base_GHCziInt_I32zh_static_info -u _base_GHCziInt_I64zh_static_info -u _base_GHCziWord_W8zh_static_info -u _base_GHCziWord_W16zh_static_info -u _base_GHCziWord_W32zh_static_info -u _base_GHCziWord_W64zh_static_info -u _base_GHCziStable_StablePtr_static_info -u _ghczmprim_GHCziTypes_Izh_con_info -u _ghczmprim_GHCziTypes_Czh_con_info -u _ghczmprim_GHCziTypes_Fzh_con_info -u _ghczmprim_GHCziTypes_Dzh_con_info -u _base_GHCziPtr_Ptr_con_info -u _base_GHCziPtr_FunPtr_con_info -u _base_GHCziStable_StablePtr_con_info -u _ghczmprim_GHCziTypes_False_closure -u _ghczmprim_GHCziTypes_True_closure -u _base_GHCziPack_unpackCString_closure -u _base_GHCziIOziException_stackOverflow_closure -u _base_GHCziIOziException_heapOverflow_closure -u _base_ControlziExceptionziBase_nonTermination_closure -u _base_GHCziIOziException_blockedIndefinitelyOnMVar_closure -u _base_GHCziIOziException_blockedIndefinitelyOnSTM_closure -u _base_ControlziExceptionziBase_nestedAtomically_closure -u _base_GHCziWeak_runFinalizzerBatch_closure -u _base_GHCziTopHandler_flushStdHandles_closure -u _base_GHCziTopHandler_runIO_closure -u _base_GHCziTopHandler_runNonIO_closure -u _base_GHCziConcziIO_ensureIOManagerIsRunning_closure -u _base_GHCziConcziSync_runSparks_closure -u _base_GHCziConcziSignal_runHandlers_closure -Wl,-search_paths_first -m64 -o queens_Trace_serial.exe


/usr/bin/i686-apple-darwin11-gcc-4.2.1 

[2012.01.23] {Apparent GHC divergence (actually, GCC)}
------------------------------------------------------

This GHC command appears to have just become stuck overnight:

    ghc --make -i../ -isumeuler/  -rtsopts -fforce-recomp -DPARSCHED="Control.Monad.Par.Scheds.Trace" sumeuler/sumeuler.hs -o sumeuler/sumeuler_Trace_serial.exe

Running it again just now also gets stuck in a state using 0% CPU.

    The Glorious Glasgow Haskell Compilation System, version 7.4.0.20111219

Running GHC with a -v5 flag results in an "impossible happened":

    Deleting: /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_0.s /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_3.hscpp /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_2.hscpp /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_1.hscpp /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_0.hscpp
    Warning: deleting non-existent /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0/ghc6895_0.s
    *** Deleting temp dirs:
    Deleting: /var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6895_0
    ghc: panic! (the 'impossible' happened)
      (GHC version 7.4.0.20111219 for x86_64-apple-darwin):
	    Prelude.undefined

    Please report this as a GHC bug:  http://www.haskell.org/ghc/reportabug

(So does -v4.)  -v3 on the other hand gets stuck on GCC:

    '/usr/bin/gcc-4.2' '-m64' '-fno-stack-protector' '-m64' '-Isumeuler' '-c' '/var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc6927_0/ghc6927_0.s' '-o' 'sumeuler/sumeuler.o'

Actually the SAME thing happens with ghc-7.2.1 with a different GCC command:

   '/Developer/usr/bin/gcc' '-m64' '-fno-stack-protector' '-Isumeuler' '-c' '/var/folders/bf/d4gpq_295mzdzqkwqrfmz2gm0000gn/T/ghc7010_0/ghc7010_0.s' '-o' 'sumeuler/sumeuler.o'

So this appears to be a problem with GCC on this system.  I notice
that I've acculumulated some GCC zombie processes (unkillable with
kill -9).  So this seems to have nothing to do with GHC and everything
to do with Apple.



[2013.05.19] {First successful monad-par benchmark run via Jenkins/PBS/Delta}
-----------------------------------------------------------------------------

RUNID: d011_1368995991

