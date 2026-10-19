#include "ContactSource.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
static int frames,maxCount;
static void receive(const DJFContact *contacts,int32_t count,double timestamp) { frames++; if(count>maxCount)maxCount=count; }
int main(void) {
 int ok=DJFStartTrackpad(receive);
 printf("device=%d width=%d height=%d\n",ok,DJFTrackpadWidth(),DJFTrackpadHeight());fflush(stdout);
 CFRunLoopRunInMode(kCFRunLoopDefaultMode,5,false);
 DJFStopTrackpad();printf("frames=%d maxContacts=%d\n",frames,maxCount);
 return ok?0:1;
}
