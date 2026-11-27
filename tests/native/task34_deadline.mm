// Shared production deadline arithmetic harness. No UIKit or live AX runtime used.
// macOS next-gate build: clang++ -std=c++17 task34_deadline.mm -o task34_deadline
#include "../../pccontrol/PointDeadline.h"
#include <assert.h>
int main(void) {
    const uint64_t start=1000000000ULL;
    assert(zxPointDeadlineCode(start,start+749999999ULL,false,false)==0);
    assert(zxPointDeadlineCode(start,start+750000000ULL,false,false)==3411);
    assert(zxPointDeadlineCode(start,start+4000000000ULL,false,false)==3411);
    assert(zxPointDeadlineCode(start,start+750000000ULL,true,false)==0);
    assert(zxPointDeadlineCode(start,start+2750000000ULL,true,true)==3412);
    assert(zxPointDeadlineCode(start,start+2999999999ULL,true,false)==0);
    assert(zxPointDeadlineCode(start,start+3000000000ULL,true,false)==3412);
    assert(zxPointTimeoutSeconds(start,start)==0.5f);
    assert(zxPointTimeoutSeconds(start,start+2725000000ULL)==0);
    float remaining=zxPointTimeoutSeconds(start,start+2700000000ULL);
    assert(remaining>0.029f && remaining<0.031f);
    return 0;
}
