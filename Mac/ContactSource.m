// MultitouchSupport ABI isolated here; no raw contact data is retained.
// Structure reference: https://github.com/lauschue/Remotastic/blob/main/MultitouchSupport.h
#include "ContactSource.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <math.h>
typedef struct { float x,y; } XY;
typedef struct { XY position,velocity; } Vector;
typedef struct {
 int32_t frame; double timestamp; int32_t path,state,finger,hand;
 Vector normalized; float quality; int32_t reserved; float angle,major,minor;
 Vector absolute; int32_t reserved2[2]; float density;
} RawTouch;
_Static_assert(sizeof(RawTouch)==96,"Unexpected touch ABI");
static void *library,*device;
static CFArrayRef devices;
static DJFContactCallback consumer;
static pthread_mutex_t gate=PTHREAD_MUTEX_INITIALIZER;
static int width,height;
typedef void (*RawCallback)(void*,RawTouch*,size_t,double,size_t);
static void receive(void *source,RawTouch *touches,size_t count,double timestamp,size_t frame) {
 DJFContact output[5]; int n=0;
 for(size_t i=0;i<count && n<5;i++) {
  RawTouch t=touches[i];
  if((t.state==3 || t.state==4) && isfinite(t.normalized.position.x) && isfinite(t.normalized.position.y)
     && t.normalized.position.x>=0 && t.normalized.position.x<=1 && t.normalized.position.y>=0 && t.normalized.position.y<=1) {
   output[n++]=(DJFContact){t.path,t.normalized.position.x,t.normalized.position.y};
  }
 }
 pthread_mutex_lock(&gate);
 if(consumer) consumer(output,n,timestamp);
 pthread_mutex_unlock(&gate);
}
int DJFStartTrackpad(DJFContactCallback callback) {
 if(device) return 1;
 library=dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",RTLD_NOW);
 if(!library) return 0;
 CFArrayRef (*create)(void)=dlsym(library,"MTDeviceCreateList");
 bool (*builtIn)(void*)=dlsym(library,"MTDeviceIsBuiltIn");
 void (*registerFrame)(void*,RawCallback)=dlsym(library,"MTRegisterContactFrameCallback");
 int (*start)(void*,int)=dlsym(library,"MTDeviceStart");
 int (*size)(void*,int*,int*)=dlsym(library,"MTDeviceGetSensorSurfaceDimensions");
 if(!create || !builtIn || !registerFrame || !start) return 0;
 devices=create();
 for(CFIndex i=0;devices && i<CFArrayGetCount(devices);i++) {
  void *candidate=(void*)CFArrayGetValueAtIndex(devices,i);
  if(builtIn(candidate)) { device=candidate;break; }
 }
 if(!device) return 0;
 if(size) size(device,&width,&height);
 pthread_mutex_lock(&gate);consumer=callback;pthread_mutex_unlock(&gate);
 registerFrame(device,receive);start(device,0);
 return 1;
}
void DJFStopTrackpad(void) {
 pthread_mutex_lock(&gate);consumer=NULL;pthread_mutex_unlock(&gate);
 if(!device) return;
 int (*stop)(void*)=dlsym(library,"MTDeviceStop");
 void (*unregisterFrame)(void*,RawCallback)=dlsym(library,"MTUnregisterContactFrameCallback");
 if(stop) stop(device);
 if(unregisterFrame) unregisterFrame(device,receive);
 device=NULL;
 // Keep framework/device storage for process lifetime; callbacks may be in flight.
}
int DJFTrackpadWidth(void) { return width; }
int DJFTrackpadHeight(void) { return height; }
