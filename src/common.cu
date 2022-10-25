
/*************************************************************************
 * Copyright (c) 2016-2022, NVIDIA CORPORATION. All rights reserved.
 * Modifications Copyright (c) 2019-2022 Advanced Micro Devices, Inc. All rights reserved.
 *
 * See LICENSE.txt for license information
 ************************************************************************/

#include "hip/hip_runtime.h"
#include "rccl_bfloat16.h"
#include "common.h"
#include <pthread.h>
#include <cstdio>
#include <type_traits>
#include <getopt.h>
#include <libgen.h>

//#define DEBUG_PRINT

#include "../verifiable/verifiable.h"

int test_ncclVersion = 0; // init'd with ncclGetVersion()

#if NCCL_MAJOR >= 2
  ncclDataType_t test_types[ncclNumTypes] = {
    ncclInt8, ncclUint8, ncclInt32, ncclUint32, ncclInt64, ncclUint64, ncclHalf, ncclFloat, ncclDouble
  #if RCCL_BFLOAT16 == 1
    , ncclBfloat16
  #endif
  };
  const char *test_typenames[ncclNumTypes] = {
    "int8", "uint8", "int32", "uint32", "int64", "uint64", "half", "float", "double"
  #if RCCL_BFLOAT16 == 1
    , "bfloat16"
  #endif
  };
  int test_typenum = -1;

  const char *test_opnames[] = {"sum", "prod", "max", "min", "avg", "mulsum"};
  ncclRedOp_t test_ops[] = {ncclSum, ncclProd, ncclMax, ncclMin
  #if NCCL_VERSION_CODE >= NCCL_VERSION(2,10,0)
    , ncclAvg
  #endif
  #if NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0)
    , ncclNumOps // stand in for ncclRedOpCreatePreMulSum() created on-demand
  #endif
  };
  int test_opnum = -1;
#else
  ncclDataType_t test_types[ncclNumTypes] = {ncclChar, ncclInt, ncclHalf, ncclFloat, ncclDouble, ncclInt64, ncclUint64};
  const char *test_typenames[ncclNumTypes] = {"char", "int", "half", "float", "double", "int64", "uint64"};
  int test_typenum = 7;
  const char *test_opnames[] = {"sum", "prod", "max", "min"};
  ncclRedOp_t test_ops[] = {ncclSum, ncclProd, ncclMax, ncclMin};
  int test_opnum = 4;
#endif

const char *test_memorytypes[nccl_NUM_MTYPES] = {"coarse", "fine", "host", "managed"};

// For libnccl's < 2.13
extern "C" __attribute__((weak)) char const* ncclGetLastError(ncclComm_t comm) {
  return "";
}

int is_main_proc = 0;
thread_local int is_main_thread = 0;

// Command line parameter defaults
static int nThreads = 1;
static int nGpus = 1;
static size_t minBytes = 32*1024*1024;
static size_t maxBytes = 32*1024*1024;
static size_t stepBytes = 1*1024*1024;
static size_t stepFactor = 1;
static int datacheck = 1;
static int warmup_iters = 5;
static int iters = 20;
static int agg_iters = 1;
static int ncclop = ncclSum;
static int nccltype = ncclFloat;
static int ncclroot = 0;
static int parallel_init = 0;
static int blocking_coll = 0;
static int memorytype = 0;
static int stress_cycles = 1;
static uint32_t cumask[4];
static int streamnull = 0;
static int timeout = 0;
static int cudaGraphLaunches = 0;
static int report_cputime = 0;
// Report average iteration time: (0=RANK0,1=AVG,2=MIN,3=MAX)
static int average = 1;
static int numDevices = 1;
static int ranksPerGpu = 1;
static int enable_multiranks = 0;
static int delay_inout_place = 0;

#define NUM_BLOCKS 32

static double parsesize(const char *value) {
    long long int units;
    double size;
    char size_lit;

    int count = sscanf(value, "%lf %1s", &size, &size_lit);

    switch (count) {
    case 2:
      switch (size_lit) {
      case 'G':
      case 'g':
        units = 1024*1024*1024;
        break;
      case 'M':
      case 'm':
        units = 1024*1024;
        break;
      case 'K':
      case 'k':
        units = 1024;
        break;
      default:
        return -1.0;
      };
      break;
    case 1:
      units = 1;
      break;
    default:
      return -1.0;
    }

    return size * units;
}

static bool minReqVersion(int rmajor, int rminor, int rpatch)
{
  int version;
  int major, minor, patch, rem;
  ncclGetVersion(&version);

  if (version < 10000) {
    major = version/1000;
    rem   = version%1000;
    minor = rem/100;
    patch = rem%100;
  }
  else {
    major = version/10000;
    rem   = version%10000;
    minor = rem/100;
    patch = rem%100;
  }

  if (major < rmajor)      return false;
  else if (major > rmajor) return true;

  // major == rmajor
  if (minor < rminor)      return false;
  else if (minor > rminor) return true;

  // major == rmajor && minor == rminor
  if (patch < rpatch)      return false;

  return true;
}

testResult_t CheckDelta(void* results, void* expected, size_t count, size_t offset, ncclDataType_t type, ncclRedOp_t op, uint64_t seed, int nranks, int64_t *wrongEltN) {
  ncclVerifiableVerify(results, expected, count, (int)type, (int)op, nranks, seed, offset, wrongEltN, hipStreamDefault);
  HIPCHECK(hipDeviceSynchronize());
  return testSuccess;
}

testResult_t InitDataReduce(void* data, const size_t count, const size_t offset, ncclDataType_t type, ncclRedOp_t op, uint64_t seed, int nranks) {
  ncclVerifiablePrepareExpected(data, count, (int)type, (int)op, nranks, seed, offset, hipStreamDefault);
  return testSuccess;
}

testResult_t InitData(void* data, const size_t count, size_t offset, ncclDataType_t type, ncclRedOp_t op, uint64_t seed, int nranks, int rank) {
  ncclVerifiablePrepareInput(data, count, (int)type, (int)op, nranks, rank, seed, offset, hipStreamDefault);
  return testSuccess;
}

void Barrier(struct threadArgs *args) {
  thread_local int epoch = 0;
  static pthread_mutex_t lock[2] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};
  static pthread_cond_t cond[2] = {PTHREAD_COND_INITIALIZER, PTHREAD_COND_INITIALIZER};
  static int counter[2] = {0, 0};

  pthread_mutex_lock(&lock[epoch]);
  if(++counter[epoch] == args->nThreads)
    pthread_cond_broadcast(&cond[epoch]);

  if(args->thread+1 == args->nThreads) {
    while(counter[epoch] != args->nThreads)
      pthread_cond_wait(&cond[epoch], &lock[epoch]);
    #ifdef MPI_SUPPORT
      MPI_Barrier(MPI_COMM_WORLD);
    #endif
    counter[epoch] = 0;
    pthread_cond_broadcast(&cond[epoch]);
  }
  else {
    while(counter[epoch] != 0)
      pthread_cond_wait(&cond[epoch], &lock[epoch]);
  }
  pthread_mutex_unlock(&lock[epoch]);
  epoch ^= 1;
}

// Inter-thread/process barrier+allreduce. The quality of the return value
// for average=0 (which means broadcast from rank=0) is dubious. The returned
// value will actually be the result of process-local broadcast from the local thread=0.
template<typename T>
void Allreduce(struct threadArgs* args, T* value, int average) {
  thread_local int epoch = 0;
  static pthread_mutex_t lock[2] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};
  static pthread_cond_t cond[2] = {PTHREAD_COND_INITIALIZER, PTHREAD_COND_INITIALIZER};
  static T accumulator[2];
  static int counter[2] = {0, 0};

  pthread_mutex_lock(&lock[epoch]);
  if(counter[epoch] == 0) {
    if(average != 0 || args->thread == 0) accumulator[epoch] = *value;
  } else {
    switch(average) {
    case /*r0*/ 0: if(args->thread == 0) accumulator[epoch] = *value; break;
    case /*avg*/1: accumulator[epoch] += *value; break;
    case /*min*/2: accumulator[epoch] = std::min<T>(accumulator[epoch], *value); break;
    case /*max*/3: accumulator[epoch] = std::max<T>(accumulator[epoch], *value); break;
    case /*sum*/4: accumulator[epoch] += *value; break;
    }
  }

  if(++counter[epoch] == args->nThreads)
    pthread_cond_broadcast(&cond[epoch]);

  if(args->thread+1 == args->nThreads) {
    while(counter[epoch] != args->nThreads)
      pthread_cond_wait(&cond[epoch], &lock[epoch]);

    #ifdef MPI_SUPPORT
    if(average != 0) {
      static_assert(std::is_same<T, long long>::value || std::is_same<T, double>::value, "Allreduce<T> only for T in {long long, double}");
      MPI_Datatype ty = std::is_same<T, long long>::value ? MPI_LONG_LONG :
                        std::is_same<T, double>::value ? MPI_DOUBLE :
                        MPI_Datatype();
      MPI_Op op = average == 1 ? MPI_SUM :
                  average == 2 ? MPI_MIN :
                  average == 3 ? MPI_MAX :
                  average == 4 ? MPI_SUM : MPI_Op();
      MPI_Allreduce(MPI_IN_PLACE, (void*)&accumulator[epoch], 1, ty, op, MPI_COMM_WORLD);
    }
    #endif

    if(average == 1) accumulator[epoch] /= args->totalProcs*args->nThreads;
    counter[epoch] = 0;
    pthread_cond_broadcast(&cond[epoch]);
  }
  else {
    while(counter[epoch] != 0)
      pthread_cond_wait(&cond[epoch], &lock[epoch]);
  }
  pthread_mutex_unlock(&lock[epoch]);

  *value = accumulator[epoch];
  epoch ^= 1;
}

testResult_t CheckData(struct threadArgs* args, ncclDataType_t type, ncclRedOp_t op, int root, int in_place, int64_t *wrongElts) {
  int nranks = args->nProcs*args->nGpus*args->nThreads;
  size_t count = args->expectedBytes/wordSize(type);

  int64_t *wrongPerGpu = nullptr;
  HIPCHECK(hipHostMalloc((void**)&wrongPerGpu, args->nGpus*sizeof(int64_t), hipHostMallocMapped));
  
  for (int i=0; i<args->nGpus*args->nRanks; i++) {
    int device;
    int rank = ((args->proc*args->nThreads + args->thread)*args->nGpus*args->nRanks + i);
    NCCLCHECK(ncclCommCuDevice(args->comms[i], &device));
    HIPCHECK(hipSetDevice(device));
    void *data = in_place ? ((void *)((uintptr_t)args->recvbuffs[i] + args->recvInplaceOffset*rank)) : args->recvbuffs[i];

    TESTCHECK(CheckDelta(data, args->expected[i], count, 0, type, op, 0, nranks, wrongPerGpu+i));

#if 1 && DEBUG_PRINT
    if (args->reportErrors && wrongPerGpu[i] != 0) {
      printf("rank=%d #wrong=%d\n", rank, (int)wrongPerGpu[i]);
      char *expectedHost = (char*)malloc(args->expectedBytes);
      char *dataHost = (char*)malloc(args->expectedBytes);
      int eltsz = wordSize(type);
      hipMemcpy(expectedHost, args->expected[i], args->expectedBytes, hipMemcpyDeviceToHost);
      hipMemcpy(dataHost, data, args->expectedBytes, hipMemcpyDeviceToHost);

      for(int j=0; j<args->expectedBytes/eltsz; j++) {
        unsigned long long want, got;
        want = 0;
        memcpy(&want, expectedHost + j*eltsz, eltsz);
        got = 0;
        memcpy(&got, dataHost + j*eltsz, eltsz);
        if(want != got) {
          printf(" rank=%d elt[%d]: want=0x%llx got=0x%llx\n", rank, j, want, got);
        }
      }
      free(expectedHost);
      free(dataHost);
    }
#endif
  }

  *wrongElts = 0;
  for (int i=0; i < args->nGpus; i++) *wrongElts += wrongPerGpu[i];
  hipFree(wrongPerGpu);

  if (args->reportErrors && *wrongElts) args->errors[0]++;
  return testSuccess;
}
    
testResult_t testStreamSynchronize(int nStreams, hipStream_t* streams, ncclComm_t* comms) {
  hipError_t hipErr;
  int remaining = nStreams;
  int* done = (int*)malloc(sizeof(int)*nStreams);
  memset(done, 0, sizeof(int)*nStreams);
  timer tim;
  
  while (remaining) {
   int idle = 1;
   for (int i=0; i<nStreams; i++) {
     if (done[i]) continue;

     hipErr = hipStreamQuery(streams[i]);
     if (hipErr == hipSuccess) {
       done[i] = 1;
       remaining--;
       idle = 0;
       continue;
     }

     if (hipErr != hipErrorNotReady) HIPCHECK(hipErr);

#if NCCL_VERSION_CODE >= NCCL_VERSION(2,4,0)
     if (test_ncclVersion >= NCCL_VERSION(2,4,0) && comms) {
       ncclResult_t ncclAsyncErr;
       NCCLCHECK(ncclCommGetAsyncError(comms[i], &ncclAsyncErr));
       if (ncclAsyncErr != ncclSuccess) {
         // An asynchronous error happened. Stop the operation and destroy
         // the communicator
         for (int i=0; i<nStreams; i++)
           NCCLCHECK(ncclCommAbort(comms[i]));
         // Abort the perf test
         NCCLCHECK(ncclAsyncErr);
       }
     }
     double delta = tim.elapsed();
     if (delta > timeout && timeout > 0) {
       for (int i=0; i<nStreams; i++)
         NCCLCHECK(ncclCommAbort(comms[i]));
       char hostname[1024];
       getHostName(hostname, 1024);
       printf("%s: Test timeout (%ds) %s:%d\n",
           hostname,
           timeout,
           __FILE__,__LINE__);
       free(done);
       return testTimeout;
     }
#endif
   }

   // We might want to let other threads (including NCCL threads) use the CPU.
   if (idle) sched_yield();
  }
  free(done);
  return testSuccess;
}

testResult_t startColl(struct threadArgs* args, ncclDataType_t type, ncclRedOp_t opIndex, int root, int in_place, int iter) {
  size_t count = args->nbytes / wordSize(type);

  // Try to change offset for each iteration so that we avoid cache effects and catch race conditions in ptrExchange
  size_t totalnbytes = std::max(args->sendBytes, args->expectedBytes);
  size_t steps = totalnbytes ? args->maxbytes / totalnbytes : 1;
  size_t shift = totalnbytes * (iter % steps);

  if (args->nGpus> 1 || args->nRanks > 1) NCCLCHECK(ncclGroupStart());
  for (int i = 0; i < args->nGpus*args->nRanks; i++) {
#ifndef NCCL_MAJOR
    int hipDev;
    NCCLCHECK(ncclCommCuDevice(args->comms[i], &hipDev));
    HIPCHECK(hipSetDevice(hipDev));
#endif
    int rank = ((args->proc*args->nThreads + args->thread)*args->nGpus*args->nRanks + i);
    char* recvBuff = ((char*)args->recvbuffs[i]) + shift;
    char* sendBuff = ((char*)args->sendbuffs[i]) + shift;
    ncclRedOp_t op;

    if(opIndex < ncclNumOps) {
      op = opIndex;
    }
    #if NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0)
    else {
      union {
        int8_t i8; uint8_t u8; int32_t i32; uint32_t u32; int64_t i64; uint64_t u64;
        half f16; float f32; double f64;
        #if defined(RCCL_BFLOAT16)
        rccl_bfloat16 bf16;
        #endif
      };
      switch(type) {
      case ncclInt8: i8 = ncclVerifiablePremulScalar<int8_t>(rank); break;
      case ncclUint8: u8 = ncclVerifiablePremulScalar<uint8_t>(rank); break;
      case ncclInt32: i32 = ncclVerifiablePremulScalar<int32_t>(rank); break;
      case ncclUint32: u32 = ncclVerifiablePremulScalar<uint32_t>(rank); break;
      case ncclInt64: i64 = ncclVerifiablePremulScalar<int64_t>(rank); break;
      case ncclUint64: u64 = ncclVerifiablePremulScalar<uint64_t>(rank); break;
      case ncclFloat16: f16 = ncclVerifiablePremulScalar<half>(rank); break;
      case ncclFloat32: f32 = ncclVerifiablePremulScalar<float>(rank); break;
      case ncclFloat64: f64 = ncclVerifiablePremulScalar<double>(rank); break;
      #if defined(RCCL_BFLOAT16)
      case ncclBfloat16: bf16 = ncclVerifiablePremulScalar<rccl_bfloat16>(rank); break;
      #endif
      }
      NCCLCHECK(ncclRedOpCreatePreMulSum(&op, &u64, type, ncclScalarHostImmediate, args->comms[i]));
    }
    #endif

    TESTCHECK(args->collTest->runColl(
          (void*)(in_place ? recvBuff + args->sendInplaceOffset*rank : sendBuff),
          (void*)(in_place ? recvBuff + args->recvInplaceOffset*rank : recvBuff),
        count, type, op, root, args->comms[i], args->streams[i]));

    #if NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0)
    if(opIndex >= ncclNumOps) {
      NCCLCHECK(ncclRedOpDestroy(op, args->comms[i]));
    }
    #endif
  }
  if (args->nGpus > 1 || args->nRanks > 1) NCCLCHECK(ncclGroupEnd());

  if (blocking_coll) {
    // Complete op before returning
    TESTCHECK(testStreamSynchronize(args->nGpus*args->nRanks, args->streams, args->comms));
  }
  if (blocking_coll) Barrier(args);
  return testSuccess;
}

testResult_t completeColl(struct threadArgs* args) {
  if (blocking_coll) return testSuccess;

  TESTCHECK(testStreamSynchronize(args->nGpus*args->nRanks, args->streams, args->comms));
  return testSuccess;
}

//RCCL: Revisit because of cudaGraphLaunches
testResult_t BenchTime(struct threadArgs* args, ncclDataType_t type, ncclRedOp_t op, int root, int in_place) {
  size_t count = args->nbytes / wordSize(type);
  if (datacheck) {
    // Initialize sendbuffs, recvbuffs and expected
    TESTCHECK(args->collTest->initData(args, type, op, root, 99, in_place));
  }

  if (warmup_iters) {
    // Sync
    TESTCHECK(startColl(args, type, op, root, in_place, 0));
    TESTCHECK(completeColl(args));
  }

  Barrier(args);

#if HIP_VERSION >= 50221310
  hipGraph_t graphs[args->nGpus*args->nRanks];
  hipGraphExec_t graphExec[args->nGpus*args->nRanks];
  if (cudaGraphLaunches >= 1) {
    // Begin cuda graph capture
    for (int i=0; i<args->nGpus*args->nRanks; i++) {
      // Thread local mdoe is needed for:
      // - Multi-thread mode: where graph capture and instantiation can happen concurrently across threads
      // - P2P pre-connect: when there is no warm-up, P2P pre-connect is done during graph capture.
      //   Since pre-connect calls cudaMalloc, we cannot use global capture mode
      HIPCHECK(hipStreamBeginCapture(args->streams[i], hipStreamCaptureModeThreadLocal));
    }
  }
#endif

  // Performance Benchmark
  timer tim;
  for (int iter = 0; iter < iters; iter++) {
    if (agg_iters>1) NCCLCHECK(ncclGroupStart());
    for (int aiter = 0; aiter < agg_iters; aiter++) {
      TESTCHECK(startColl(args, type, op, root, in_place, iter*agg_iters+aiter));
    }
    if (agg_iters>1) NCCLCHECK(ncclGroupEnd());
  }

#if HIP_VERSION >= 50221310
  if (cudaGraphLaunches >= 1) {
    // End cuda graph capture
    for (int i=0; i<args->nGpus*args->nRanks; i++) {
      HIPCHECK(hipStreamEndCapture(args->streams[i], graphs+i));
    }
    // Instantiate cuda graph
    for (int i=0; i<args->nGpus*args->nRanks; i++) {
      HIPCHECK(hipGraphInstantiate(graphExec+i, graphs[i], NULL, NULL, 0));
    }
    // Resync CPU, restart timing, launch cuda graph
    Barrier(args);
    tim.reset();
    for (int l=0; l<cudaGraphLaunches; l++) {
      for (int i=0; i<args->nGpus*args->nRanks; i++) {
        HIPCHECK(hipGraphLaunch(graphExec[i], args->streams[i]));
      }
    }
  }
#endif

  double cputimeSec = tim.elapsed()/(iters*agg_iters);
  TESTCHECK(completeColl(args));

  double deltaSec = tim.elapsed();
  deltaSec = deltaSec/(iters*agg_iters);
  if (cudaGraphLaunches >= 1) deltaSec = deltaSec/cudaGraphLaunches;
  Allreduce(args, &deltaSec, average);

#if HIP_VERSION >= 50221310
  if (cudaGraphLaunches >= 1) {
    //destroy cuda graph
    for (int i=0; i<args->nGpus*args->nRanks; i++) {
      HIPCHECK(hipGraphExecDestroy(graphExec[i]));
      HIPCHECK(hipGraphDestroy(graphs[i]));
    }
  }
#endif

  double algBw, busBw;
  args->collTest->getBw(count, wordSize(type), deltaSec, &algBw, &busBw, args->nProcs*args->nThreads*args->nGpus*args->nRanks);

  Barrier(args);

  int64_t wrongElts = 0;
  static __thread int rep = 0;
  rep++;
  if (datacheck) {
      // Initialize sendbuffs, recvbuffs and expected
      TESTCHECK(args->collTest->initData(args, type, op, root, rep, in_place));

#if HIP_VERSION >= 50221310
      if (cudaGraphLaunches >= 1) {
        // Begin cuda graph capture for data check
        for (int i=0; i<args->nGpus*args->nRanks; i++) {
          HIPCHECK(hipStreamBeginCapture(args->streams[i], args->nThreads > 1 ? hipStreamCaptureModeThreadLocal : hipStreamCaptureModeGlobal));
        }
      }
#endif

      //test validation in single itertion, should ideally be included into the multi-iteration run
      TESTCHECK(startColl(args, type, op, root, in_place, 0));

#if HIP_VERSION >= 50221310
      if (cudaGraphLaunches >= 1) {
        // End cuda graph capture
        for (int i=0; i<args->nGpus*args->nRanks; i++) {
          HIPCHECK(hipStreamEndCapture(args->streams[i], graphs+i));
        }
        // Instantiate cuda graph
        for (int i=0; i<args->nGpus*args->nRanks; i++) {
          HIPCHECK(hipGraphInstantiate(graphExec+i, graphs[i], NULL, NULL, 0));
        }
        // Launch cuda graph
        for (int i=0; i<args->nGpus*args->nRanks; i++) {
          HIPCHECK(hipGraphLaunch(graphExec[i], args->streams[i]));
        }
      }
#endif

      TESTCHECK(completeColl(args));

#if HIP_VERSION >= 50221310
      if (cudaGraphLaunches >= 1) {
        //destroy cuda graph
        for (int i=0; i<args->nGpus*args->nRanks; i++) {
          HIPCHECK(hipGraphExecDestroy(graphExec[i]));
          HIPCHECK(hipGraphDestroy(graphs[i]));
        }
      }
#endif

      TESTCHECK(CheckData(args, type, op, root, in_place, &wrongElts));

      //aggregate delta from all threads and procs
      long long wrongElts1 = wrongElts;
      Allreduce(args, &wrongElts1, /*sum*/4);
      wrongElts = wrongElts1;
  }

  double timeUsec = (report_cputime ? cputimeSec : deltaSec)*1.0E6;
  char timeStr[100];
  if (timeUsec >= 10000.0) {
    sprintf(timeStr, "%7.0f", timeUsec);
  } else if (timeUsec >= 100.0) {
    sprintf(timeStr, "%7.1f", timeUsec);
  } else {
    sprintf(timeStr, "%7.2f", timeUsec);
  }
  if (args->reportErrors) {
    PRINT("  %7s  %6.2f  %6.2f  %5g", timeStr, algBw, busBw, (double)wrongElts);
  } else {
    PRINT("  %7s  %6.2f  %6.2f  %5s", timeStr, algBw, busBw, "N/A");
  }

  args->bw[0] += busBw;
  args->bw_count[0]++;
  return testSuccess;
}

void setupArgs(size_t size, ncclDataType_t type, struct threadArgs* args) {
  int nranks = args->nProcs*args->nGpus*args->nThreads*args->nRanks;
  size_t count, sendCount, recvCount, paramCount, sendInplaceOffset, recvInplaceOffset;

  count = size / wordSize(type);
  args->collTest->getCollByteCount(&sendCount, &recvCount, &paramCount, &sendInplaceOffset, &recvInplaceOffset, (size_t)count, (size_t)nranks);

  args->nbytes = paramCount * wordSize(type);
  args->sendBytes = sendCount * wordSize(type);
  args->expectedBytes = recvCount * wordSize(type);
  args->sendInplaceOffset = sendInplaceOffset * wordSize(type);
  args->recvInplaceOffset = recvInplaceOffset * wordSize(type);
}

testResult_t TimeTest(struct threadArgs* args, ncclDataType_t type, const char* typeName, ncclRedOp_t op, const char* opName, int root) {
  // Sync to avoid first-call timeout
  Barrier(args);

  // Warm-up for large size
  setupArgs(args->maxbytes, type, args);
  for (int iter = 0; iter < warmup_iters; iter++) {
    TESTCHECK(startColl(args, type, op, root, 0, iter));
  }
  TESTCHECK(completeColl(args));

  // Warm-up for small size
  setupArgs(args->minbytes, type, args);
  for (int iter = 0; iter < warmup_iters; iter++) {
    TESTCHECK(startColl(args, type, op, root, 0, iter));
  }
  TESTCHECK(completeColl(args));

  for (size_t iter = 0; iter < stress_cycles; iter++) {
    if (iter > 0) PRINT("# Testing %lu cycle.\n", iter+1);
    // Benchmark
    for (size_t size = args->minbytes; size<=args->maxbytes; size = ((args->stepfactor > 1) ? size*args->stepfactor : size+args->stepbytes)) {
        setupArgs(size, type, args);
	char rootName[100];
	sprintf(rootName, "%6i", root);	
	PRINT("%12li  %12li  %8s  %6s  %6s", (size_t)max(args->sendBytes, args->expectedBytes), args->nbytes / wordSize(type), typeName, opName, rootName);
        TESTCHECK(BenchTime(args, type, op, root, 0));
        usleep(delay_inout_place);
        TESTCHECK(BenchTime(args, type, op, root, 1));
        PRINT("\n");
    }
  }
  return testSuccess;
}

testResult_t threadRunTests(struct threadArgs* args) {
  // Set device to the first of our GPUs. If we don't do that, some operations
  // will be done on the current GPU (by default : 0) and if the GPUs are in
  // exclusive mode those operations will fail.
  HIPCHECK(hipSetDevice(args->gpus[0]));
  TESTCHECK(ncclTestEngine.runTest(args, ncclroot, (ncclDataType_t)nccltype, test_typenames[nccltype], (ncclRedOp_t)ncclop, test_opnames[ncclop]));
  return testSuccess;
}

testResult_t threadInit(struct threadArgs* args) {
  char hostname[1024];
  getHostName(hostname, 1024);
  int nranks =  args->nProcs*args->nThreads*args->nGpus*args->nRanks;

  //set main thread again
  is_main_thread = (is_main_proc && args->thread == 0) ? 1 : 0;

  NCCLCHECK(ncclGroupStart());
  for (int i=0; i<args->nGpus; i++) {
    HIPCHECK(hipSetDevice(args->gpus[i]));

    for (int j=0; j<args->nRanks; j++) {
      int rank = (args->proc*args->nThreads + args->thread)*args->nGpus*args->nRanks + i*args->nRanks + j;
      if (args->enable_multiranks)
	NCCLCHECK(ncclCommInitRank(args->comms+i, nranks, args->ncclId, rank));
#ifdef RCCL_MULTIRANKPERGPU
      else
	NCCLCHECK(ncclCommInitRankMulti(args->comms+i*args->nRanks+j, nranks, args->ncclId, rank, rank));
#endif
    }
  }
  NCCLCHECK(ncclGroupEnd());

  TESTCHECK(threadRunTests(args));

  for (int i=0; i<args->nGpus*args->nRanks; i++) {
    NCCLCHECK(ncclCommDestroy(args->comms[i]));
  }
  return testSuccess;
}

void* threadLauncher(void* thread_) {
  struct testThread* thread = (struct testThread*)thread_;
  thread->ret = thread->func(&thread->args);
  return NULL;
}
testResult_t threadLaunch(struct testThread* thread) {
  pthread_create(&thread->thread, NULL, threadLauncher, thread);
  return testSuccess;
}

testResult_t AllocateBuffs(void **sendbuff, size_t sendBytes, void **recvbuff, size_t recvBytes, void **expected, size_t nbytes) {
  if (memorytype == ncclFine) {
    HIPCHECK(hipExtMallocWithFlags(sendbuff, nbytes, hipDeviceMallocFinegrained));
    HIPCHECK(hipExtMallocWithFlags(recvbuff, nbytes, hipDeviceMallocFinegrained));
    if (datacheck) HIPCHECK(hipExtMallocWithFlags(expected, recvBytes, hipDeviceMallocFinegrained));
  }
  else if (memorytype == ncclHost) {
    HIPCHECK(hipHostMalloc(sendbuff, nbytes));
    HIPCHECK(hipHostMalloc(recvbuff, nbytes));
    if (datacheck) HIPCHECK(hipHostMalloc(expected, recvBytes));
  }
  else if (memorytype == ncclManaged) {
    HIPCHECK(hipMallocManaged(sendbuff, nbytes));
    HIPCHECK(hipMallocManaged(recvbuff, nbytes));
    if (datacheck) HIPCHECK(hipMallocManaged(expected, recvBytes));
#if 0
    HIPCHECK(hipMemset(*sendbuff, 0, nbytes));
    HIPCHECK(hipMemset(*recvbuff, 0, nbytes));
    if (datacheck) HIPCHECK(hipMemset(*expected, 0, recvBytes));
#endif
  }
  else {
    HIPCHECK(hipMalloc(sendbuff, nbytes));
    HIPCHECK(hipMalloc(recvbuff, nbytes));
    if (datacheck) HIPCHECK(hipMalloc(expected, recvBytes));
  }
  return testSuccess;
}

testResult_t run(); // Main function

int main(int argc, char* argv[]) {
  // Make sure everyline is flushed so that we see the progress of the test
  setlinebuf(stdout);

  #if NCCL_VERSION_CODE >= NCCL_VERSION(2,4,0)
    ncclGetVersion(&test_ncclVersion);
  #else
    test_ncclVersion = NCCL_VERSION_CODE;
  #endif
  //printf("# NCCL_VERSION_CODE=%d ncclGetVersion=%d\n", NCCL_VERSION_CODE, test_ncclVersion);
  #if NCCL_VERSION_CODE >= NCCL_VERSION(2,0,0)
    test_opnum = 4;
    test_typenum = 9;
    if (NCCL_VERSION_CODE >= NCCL_VERSION(2,10,0) && test_ncclVersion >= NCCL_VERSION(2,10,0)) {
      test_opnum++; // ncclAvg
      #if defined(RCCL_BFLOAT16)
        test_typenum++; // bfloat16
      #endif
    }
    if (NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0) && test_ncclVersion >= NCCL_VERSION(2,11,0)) {
      test_opnum++; // PreMulSum
    }
  #endif

  // Parse args
  double parsed;
  int longindex;
  static struct option longopts[] = {
    {"nthreads", required_argument, 0, 't'},
    {"ngpus", required_argument, 0, 'g'},
    {"minbytes", required_argument, 0, 'b'},
    {"maxbytes", required_argument, 0, 'e'},
    {"stepbytes", required_argument, 0, 'i'},
    {"stepfactor", required_argument, 0, 'f'},
    {"iters", required_argument, 0, 'n'},
    {"agg_iters", required_argument, 0, 'm'},
    {"warmup_iters", required_argument, 0, 'w'},
    {"parallel_init", required_argument, 0, 'p'},
    {"check", required_argument, 0, 'c'},
    {"op", required_argument, 0, 'o'},
    {"datatype", required_argument, 0, 'd'},
    {"root", required_argument, 0, 'r'},
    {"blocking", required_argument, 0, 'z'},
    {"memory_type", required_argument, 0, 'y'}, //RCCL
    {"stress_cycles", required_argument, 0, 's'}, //RCCL
    {"cumask", required_argument, 0, 'u'},        //RCCL
    {"stream_null", required_argument, 0, 'y'}, //NCCL
    {"timeout", required_argument, 0, 'T'},     //NCCL
    {"cudagraph", required_argument, 0, 'G'},
    {"report_cputime", required_argument, 0, 'C'},
    {"average", required_argument, 0, 'a'},
#ifdef RCCL_MULTIRANKPERGPU
    {"enable_multiranks", required_argument, 0, 'x'},
    {"ranks_per_gpu", required_argument, 0, 'R'},
#endif
    {"help", no_argument, 0, 'h'},
    {}
  };

  while(1) {
    int c;

#ifdef RCCL_MULTIRANKPERGPU    
    c = getopt_long(argc, argv, "t:g:b:e:i:f:n:m:w:p:c:o:d:r:z:Y:T:G:C:a:y:s:u:h:R:x:q:", longopts, &longindex);
#else
    c = getopt_long(argc, argv, "t:g:b:e:i:f:n:m:w:p:c:o:d:r:z:Y:T:G:C:a:y:s:u:h:q:", longopts, &longindex);
#endif

    if (c == -1)
      break;

    switch(c) {
      case 't':
        nThreads = strtol(optarg, NULL, 0);
        break;
      case 'g':
        nGpus = strtol(optarg, NULL, 0);
        break;
      case 'b':
        parsed = parsesize(optarg);
        if (parsed < 0) {
          fprintf(stderr, "invalid size specified for 'minbytes'\n");
          return -1;
        }
        minBytes = (size_t)parsed;
        break;
      case 'e':
        parsed = parsesize(optarg);
        if (parsed < 0) {
          fprintf(stderr, "invalid size specified for 'maxbytes'\n");
          return -1;
        }
        maxBytes = (size_t)parsed;
        break;
      case 'i':
        stepBytes = strtol(optarg, NULL, 0);
        break;
      case 'f':
        stepFactor = strtol(optarg, NULL, 0);
        break;
      case 'n':
        iters = (int)strtol(optarg, NULL, 0);
        break;
      case 'm':
#if NCCL_MAJOR > 2 || (NCCL_MAJOR >= 2 && NCCL_MINOR >= 2)
        agg_iters = (int)strtol(optarg, NULL, 0);
#else
        fprintf(stderr, "Option -m not supported before NCCL 2.2. Ignoring\n");
#endif
        break;
      case 'w':
        warmup_iters = (int)strtol(optarg, NULL, 0);
        break;
      case 'c':
        datacheck = (int)strtol(optarg, NULL, 0);
        break;
      case 'p':
        parallel_init = (int)strtol(optarg, NULL, 0);
        break;
      case 'o':
        ncclop = ncclstringtoop(optarg);
        break;
      case 'd':
        nccltype = ncclstringtotype(optarg);
        break;
      case 'r':
        ncclroot = strtol(optarg, NULL, 0);
        break;
      case 'z':
        blocking_coll = strtol(optarg, NULL, 0);
        break;
      case 'Y':
        memorytype = ncclstringtomtype(optarg);
        break;
      case 's':
        stress_cycles = strtol(optarg, NULL, 0);
        break;
      case 'u':
        {
          int nmasks = 0;
          char *mask = strtok(optarg, ",");
          while (mask != NULL && nmasks < 4) {
            cumask[nmasks++] = strtol(mask, NULL, 16);
            mask = strtok(NULL, ",");
          };
        }
	break;
      case 'y':
        streamnull = strtol(optarg, NULL, 0);
        break;
      case 'T':
        timeout = strtol(optarg, NULL, 0);
        break;
      case 'G':
#if (NCCL_MAJOR > 2 || (NCCL_MAJOR >= 2 && NCCL_MINOR >= 9)) && HIP_VERSION >= 50221310
        cudaGraphLaunches = strtol(optarg, NULL, 0);
#else
        printf("Option -G (HIP graph) not supported before NCCL 2.9 + ROCm 5.2 Ignoring\n");
#endif
        break;
      case 'C':
        report_cputime = strtol(optarg, NULL, 0);
        break;
      case 'a':
        average = (int)strtol(optarg, NULL, 0);
        break;
#ifdef RCCL_MULTIRANKPERGPU
      case 'x':
        enable_multiranks = (int)strtol(optarg, NULL, 0);
        break;
      case 'R':
        ranksPerGpu = (int)strtol(optarg, NULL, 0);
        break;
#endif
      case 'q':
        delay_inout_place = (int)strtol(optarg, NULL, 10);
        break;
      case 'h':
      default:
        if (c != 'h') printf("invalid option '%c'\n", c);
        printf("USAGE: %s \n\t"
            "[-t,--nthreads <num threads>] \n\t"
            "[-g,--ngpus <gpus per thread>] \n\t"
            "[-b,--minbytes <min size in bytes>] \n\t"
            "[-e,--maxbytes <max size in bytes>] \n\t"
            "[-i,--stepbytes <increment size>] \n\t"
            "[-f,--stepfactor <increment factor>] \n\t"
            "[-n,--iters <iteration count>] \n\t"
            "[-m,--agg_iters <aggregated iteration count>] \n\t"
            "[-w,--warmup_iters <warmup iteration count>] \n\t"
            "[-p,--parallel_init <0/1>] \n\t"
            "[-c,--check <0/1>] \n\t"
#if NCCL_VERSION_CODE >= NCCL_VERSION(2,11,0)
            "[-o,--op <sum/prod/min/max/avg/mulsum/all>] \n\t"
#elif NCCL_VERSION_CODE >= NCCL_VERSION(2,10,0)
            "[-o,--op <sum/prod/min/max/avg/all>] \n\t"
#else
            "[-o,--op <sum/prod/min/max/all>] \n\t"
#endif
            "[-d,--datatype <nccltype/all>] \n\t"
            "[-r,--root <root>] \n\t"
            "[-z,--blocking <0/1>] \n\t"
            "[-Y,--memory_type <coarse/fine/host/managed>] \n\t"
            "[-s,--stress_cycles <number of cycles>] \n\t"
            "[-u,--cumask <d0,d1,d2,d3>] \n\t"
            "[-y,--stream_null <0/1>] \n\t"
            "[-T,--timeout <time in seconds>] \n\t"
            "[-G,--cudagraph <num graph launches>] \n\t"
            "[-C,--report_cputime <0/1>] \n\t"
            "[-a,--average <0/1/2/3> report average iteration time <0=RANK0/1=AVG/2=MIN/3=MAX>] \n\t"
#ifdef RCCL_MULTIRANKPERGPU
            "[-x,--enable_multiranks <0/1> enable using multiple ranks per GPU] \n\t"
            "[-R,--ranks_per_gpu] \n\t"
#endif
            "[-q,--delay <delay between out-of-place and in-place in microseconds>] \n\t"
            "[-h,--help]\n",
          basename(argv[0]));
        return 0;
    }
  }

  HIPCHECK(hipGetDeviceCount(&numDevices));
  if (nGpus > numDevices)
  {
      fprintf(stderr, "[ERROR] The number of requested GPUs (%d) is greater than the number of GPUs available (%d)\n", nGpus, numDevices);
      return testNcclError;
  }
  if (minBytes > maxBytes) {
    fprintf(stderr, "invalid sizes for 'minbytes' and 'maxbytes': %llu > %llu\n",
           (unsigned long long)minBytes,
           (unsigned long long)maxBytes);
    return -1;
  }
  if (!minReqVersion(2, 12, 12) && enable_multiranks) {
     fprintf(stderr, "Multiple Ranks per GPU requested, but rccl library found does not support this feature.\n");
     fprintf(stderr, "Please check LD_LIBRARY_PATH. Resetting enable_multiranks and ranksPerGpu to default values.\n");
     enable_multiranks = 0;
     ranksPerGpu       = 1;
  }

  if (enable_multiranks && parallel_init) {
    fprintf(stderr, "Cannot use parallel_init when using multiple ranks per GPU.\n");
    return -1;
  }
  if (ranksPerGpu > 1 && !enable_multiranks) {
    fprintf(stderr, "Need to enable multiranks option to use multiple ranks per GPU\n");
    return -1;
  }
#ifdef MPI_SUPPORT
  MPI_Init(&argc, &argv);
#endif
  TESTCHECK(run());
  return 0;
}

testResult_t run() {
  int totalProcs = 1, proc = 0, ncclProcs = 1, ncclProc = 0, color = 0;
  int localRank = 0;
  char hostname[1024];
  getHostName(hostname, 1024);

#ifdef MPI_SUPPORT
  MPI_Comm_size(MPI_COMM_WORLD, &totalProcs);
  MPI_Comm_rank(MPI_COMM_WORLD, &proc);
  uint64_t hostHashs[totalProcs];
  hostHashs[proc] = getHostHash(hostname);
  MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, hostHashs, sizeof(uint64_t), MPI_BYTE, MPI_COMM_WORLD);
  for (int p=0; p<totalProcs; p++) {
    if (p == proc) break;
    if (hostHashs[p] == hostHashs[proc]) localRank++;
  }

  char* str = getenv("NCCL_TESTS_SPLIT_MASK");
  uint64_t mask = str ? strtoul(str, NULL, 16) : 0;
  MPI_Comm mpi_comm;
  color = proc & mask;
  MPI_Comm_split(MPI_COMM_WORLD, color, proc, &mpi_comm);
  MPI_Comm_size(mpi_comm, &ncclProcs);
  MPI_Comm_rank(mpi_comm, &ncclProc);
#endif
  is_main_thread = is_main_proc = (proc == 0) ? 1 : 0;

  PRINT("# nThreads: %d nGpus: %d nRanks: %d minBytes: %ld maxBytes: %ld step: %ld(%s) warmupIters: %d iters: %d agg iters: %d validation: %d graph: %d\n",
	nThreads, nGpus, ranksPerGpu, minBytes, maxBytes,
	(stepFactor > 1)?stepFactor:stepBytes, (stepFactor > 1)?"factor":"bytes",
	warmup_iters, iters, agg_iters, datacheck, cudaGraphLaunches);
  if (blocking_coll) PRINT("# Blocking Enabled: wait for completion and barrier after each collective \n");
  if (parallel_init) PRINT("# Parallel Init Enabled: threads call into NcclInitRank concurrently \n");
  PRINT("#\n");

  PRINT("# Using devices\n");
#define MAX_LINE 2048
  char line[MAX_LINE];
  int len = 0;
  size_t maxMem = ~0;
  char* envstr = getenv("NCCL_TESTS_DEVICE");
  int gpu0 = envstr ? atoi(envstr) : -1;
  for (int i=0; i<nThreads*nGpus; i++) {
    int hipDev = localRank*nThreads*nGpus+i;
    if (enable_multiranks)
      hipDev = hipDev % numDevices;
    hipDeviceProp_t prop;
    HIPCHECK(hipGetDeviceProperties(&prop, hipDev));

    for (int j=0; j<ranksPerGpu; j++) {
	int rank = proc*nThreads*nGpus*ranksPerGpu+i*ranksPerGpu + j;
        char busIdStr[] = "00000000:00:00.0";
    	HIPCHECK(hipDeviceGetPCIBusId(busIdStr, sizeof(busIdStr), hipDev));
	len += snprintf(line+len, MAX_LINE>len ? MAX_LINE-len : 0, "#   Rank %2d Pid %6d on %10s device %2d [%s] %s\n",
			rank, getpid(), hostname, hipDev, busIdStr, prop.name);
	maxMem = std::min(maxMem, prop.totalGlobalMem);
    }
  }
#if MPI_SUPPORT
  char *lines = (proc == 0) ? (char *)malloc(totalProcs*MAX_LINE) : NULL;
  // Gather all output in rank order to root (0)
  MPI_Gather(line, MAX_LINE, MPI_BYTE, lines, MAX_LINE, MPI_BYTE, 0, MPI_COMM_WORLD);
  if (proc == 0) {
    for (int p = 0; p < totalProcs; p++)
      PRINT("%s", lines+MAX_LINE*p);
    free(lines);
  }
  MPI_Allreduce(MPI_IN_PLACE, &maxMem, 1, MPI_LONG, MPI_MIN, MPI_COMM_WORLD);
#else
  PRINT("%s", line);
#endif

  // We need sendbuff, recvbuff, expected (when datacheck enabled), plus 1G for the rest.
  size_t memMaxBytes = (maxMem - (1<<30)) / (datacheck ? 3 : 2);
  if (maxBytes > memMaxBytes) {
    maxBytes = memMaxBytes;
    if (proc == 0) printf("#\n# Reducing maxBytes to %ld due to memory limitation\n", maxBytes);
  }

  ncclUniqueId ncclId;
  if (ncclProc == 0) {
    NCCLCHECK(ncclGetUniqueId(&ncclId));
  }
#ifdef MPI_SUPPORT
  MPI_Bcast(&ncclId, sizeof(ncclId), MPI_BYTE, 0, mpi_comm);
#endif

  int gpus[nGpus*nThreads];
  hipStream_t streams[nGpus*nThreads*ranksPerGpu];
  void* sendbuffs[nGpus*nThreads*ranksPerGpu];
  void* recvbuffs[nGpus*nThreads*ranksPerGpu];
  void* expected[nGpus*nThreads*ranksPerGpu];
  size_t sendBytes, recvBytes;

  ncclTestEngine.getBuffSize(&sendBytes, &recvBytes, (size_t)maxBytes, (size_t)ncclProcs*nGpus*nThreads*ranksPerGpu);

  envstr = getenv("NCCL_TESTS_DEVICE");
  gpu0 = envstr ? atoi(envstr) : -1;
  for (int ii=0; ii<nGpus*nThreads; ii++) {
    int gpuid = localRank*nThreads*nGpus+ii;
    if (enable_multiranks)
      gpuid = gpuid % numDevices;

    gpus[ii] = gpu0 != -1 ? gpu0+ii : gpuid;
    HIPCHECK(hipSetDevice(gpus[ii]));

    for (int j=0; j<ranksPerGpu; j++) {
      int i = ii*ranksPerGpu+j;

      TESTCHECK(AllocateBuffs(sendbuffs+i, sendBytes, recvbuffs+i, recvBytes, expected+i, (size_t)maxBytes));
      if (streamnull)
      	streams[i] = NULL;
      else {
	      if (cumask[0] || cumask[1] || cumask[2] || cumask[3]) {
	         PRINT("cumask: ");
	         for (int i = 0; i < 4 ; i++) PRINT("%x,", cumask[i]);
	         PRINT("\n");
	         HIPCHECK(hipExtStreamCreateWithCUMask(streams+i, 4, cumask));
	      } else
	         HIPCHECK(hipStreamCreateWithFlags(streams+i, hipStreamNonBlocking));
      }
    }
  }
  //if parallel init is not selected, use main thread to initialize NCCL
  ncclComm_t* comms = (ncclComm_t*)malloc(sizeof(ncclComm_t)*nThreads*nGpus*ranksPerGpu);
  if (!parallel_init) {
     if (ncclProcs == 1 && !enable_multiranks) {
       NCCLCHECK(ncclCommInitAll(comms, nGpus*nThreads, gpus));
     } else {
       NCCLCHECK(ncclGroupStart());
       for (int ii=0; ii<nGpus*nThreads; ii++) {
         HIPCHECK(hipSetDevice(gpus[ii]));
	 if (!enable_multiranks) {
	   NCCLCHECK(ncclCommInitRank(comms+ii, ncclProcs*nThreads*nGpus, ncclId, proc*nThreads*nGpus+ii));
	 }
#ifdef RCCL_MULTIRANKPERGPU
	 else
	   for (int j=0; j<ranksPerGpu; j++) {
	     int i = ii*ranksPerGpu+j;
	     NCCLCHECK(ncclCommInitRankMulti(comms+i, ncclProcs*nThreads*nGpus*ranksPerGpu, ncclId,
					     proc*nThreads*nGpus*ranksPerGpu+i, proc*nThreads*nGpus*ranksPerGpu+i));
	   }
#endif
       }
       NCCLCHECK(ncclGroupEnd());
     }
  }

  int errors[nThreads];
  double bw[nThreads];
  double* delta;
  HIPCHECK(hipHostMalloc(&delta, sizeof(double)*nThreads*NUM_BLOCKS, hipHostMallocPortable | hipHostMallocMapped));
  int bw_count[nThreads];
  for (int t=0; t<nThreads; t++) {
    bw[t] = 0.0;
    errors[t] = bw_count[t] = 0;
  }

  const char* timeStr = report_cputime ? "cputime" : "time";
  PRINT("#\n");
  PRINT("# %10s  %12s  %8s  %6s  %6s           out-of-place                       in-place          \n", "", "", "", "", "");
  PRINT("# %10s  %12s  %8s  %6s  %6s  %7s  %6s  %6s %6s  %7s  %6s  %6s %6s\n", "size", "count", "type", "redop", "root",
      timeStr, "algbw", "busbw", "#wrong", timeStr, "algbw", "busbw", "#wrong");
  PRINT("# %10s  %12s  %8s  %6s  %6s  %7s  %6s  %6s  %5s  %7s  %6s  %6s  %5s\n", "(B)", "(elements)", "", "", "",
      "(us)", "(GB/s)", "(GB/s)", "", "(us)", "(GB/s)", "(GB/s)", "");

  struct testThread threads[nThreads];
  memset(threads, 0, sizeof(struct testThread)*nThreads);

  for (int t=nThreads-1; t>=0; t--) {
    threads[t].args.minbytes=minBytes;
    threads[t].args.maxbytes=maxBytes;
    threads[t].args.stepbytes=stepBytes;
    threads[t].args.stepfactor=stepFactor;
    threads[t].args.localRank = localRank;

    threads[t].args.totalProcs = totalProcs;
    threads[t].args.localNumDevices = numDevices;
    threads[t].args.enable_multiranks = enable_multiranks;
    threads[t].args.nRanks = ranksPerGpu;
    threads[t].args.nProcs=ncclProcs;
    threads[t].args.proc=ncclProc;
    threads[t].args.nThreads=nThreads;
    threads[t].args.thread=t;
    threads[t].args.nGpus=nGpus;
    threads[t].args.gpus=gpus+t*nGpus;
    threads[t].args.sendbuffs = sendbuffs+t*nGpus*ranksPerGpu;
    threads[t].args.recvbuffs = recvbuffs+t*nGpus*ranksPerGpu;
    threads[t].args.expected = expected+t*nGpus*ranksPerGpu;
    threads[t].args.ncclId = ncclId;
    threads[t].args.comms=comms+t*nGpus*ranksPerGpu;
    threads[t].args.streams=streams+t*nGpus*ranksPerGpu;

    threads[t].args.errors=errors+t;
    threads[t].args.bw=bw+t;
    threads[t].args.bw_count=bw_count+t;

    threads[t].args.reportErrors = datacheck;

    threads[t].func = parallel_init ? threadInit : threadRunTests;
    if (t)
      TESTCHECK(threadLaunch(threads+t));
    else
      TESTCHECK(threads[t].func(&threads[t].args));
  }

  // Wait for other threads and accumulate stats and errors
  for (int t=nThreads-1; t>=0; t--) {
    if (t) pthread_join(threads[t].thread, NULL);
    TESTCHECK(threads[t].ret);
    if (t) {
      errors[0] += errors[t];
      bw[0] += bw[t];
      bw_count[0] += bw_count[t];
    }
  }

#ifdef MPI_SUPPORT
  MPI_Allreduce(MPI_IN_PLACE, &errors[0], 1, MPI_INT, MPI_SUM, MPI_COMM_WORLD);
#endif

  if (!parallel_init) {
    for(int i=0; i<nGpus*nThreads*ranksPerGpu; ++i)
      NCCLCHECK(ncclCommDestroy(comms[i]));
    free(comms);
  }

  for (int i=0; i<nGpus*nThreads*ranksPerGpu; i++) {
    HIPCHECK(hipStreamDestroy(streams[i]));
  }

  // Free off HIP allocated memory
  for (int i=0; i<nGpus*nThreads*ranksPerGpu; i++) {
    if (memorytype == ncclHost) {
      HIPCHECK(hipHostFree(sendbuffs[i]));
      HIPCHECK(hipHostFree(recvbuffs[i]));
      if (datacheck) HIPCHECK(hipHostFree(expected[i]));
    }
    else {
      HIPCHECK(hipFree(sendbuffs[i]));
      HIPCHECK(hipFree(recvbuffs[i]));
      if (datacheck) HIPCHECK(hipFree(expected[i]));
    }
  }
  HIPCHECK(hipHostFree(delta));

  envstr = getenv("NCCL_TESTS_MIN_BW");
  double check_avg_bw = envstr ? atof(envstr) : -1;
  bw[0] /= bw_count[0];

  if (datacheck) PRINT("# Errors with asterisks indicate errors that have exceeded the maximum threshold.\n");
  PRINT("# Out of bounds values : %d %s\n", errors[0], errors[0] ? "FAILED" : "OK");
  PRINT("# Avg bus bandwidth    : %g %s\n", bw[0], check_avg_bw == -1 ? "" : (bw[0] < check_avg_bw*(0.9) ? "FAILED" : "OK"));
  PRINT("#\n");
#ifdef MPI_SUPPORT
  MPI_Finalize();
#endif

  // 'hip-memcheck --leak-check full' requires this
  PRINT("%s\n", ncclGetLastError(NULL));
  hipDeviceReset();

  if (errors[0] || bw[0] < check_avg_bw*(0.9))
    exit(EXIT_FAILURE);
  else
    exit(EXIT_SUCCESS);
}
