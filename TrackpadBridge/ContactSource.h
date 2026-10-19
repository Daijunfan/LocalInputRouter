#include <stdint.h>
typedef struct { int32_t id; double x,y; } DJFContact;
typedef void (*DJFContactCallback)(const DJFContact *contacts, int32_t count, double timestamp);
int DJFStartTrackpad(DJFContactCallback callback);
void DJFStopTrackpad(void);
int DJFTrackpadWidth(void);
int DJFTrackpadHeight(void);
