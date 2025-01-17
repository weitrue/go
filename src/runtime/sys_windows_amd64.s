// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

#include "go_asm.h"
#include "go_tls.h"
#include "textflag.h"

// maxargs should be divisible by 2, as Windows stack
// must be kept 16-byte aligned on syscall entry.
#define maxargs 18

// void runtime·asmstdcall(void *c);
TEXT runtime·asmstdcall<ABIInternal>(SB),NOSPLIT|NOFRAME,$0
	// asmcgocall will put first argument into CX.
	PUSHQ	CX			// save for later
	MOVQ	libcall_fn(CX), AX
	MOVQ	libcall_args(CX), SI
	MOVQ	libcall_n(CX), CX

	// SetLastError(0).
	MOVQ	0x30(GS), DI
	MOVL	$0, 0x68(DI)

	SUBQ	$(maxargs*8), SP	// room for args

	// Fast version, do not store args on the stack.
	CMPL	CX, $4
	JLE	loadregs

	// Check we have enough room for args.
	CMPL	CX, $maxargs
	JLE	2(PC)
	INT	$3			// not enough room -> crash

	// Copy args to the stack.
	MOVQ	SP, DI
	CLD
	REP; MOVSQ
	MOVQ	SP, SI

loadregs:
	// Load first 4 args into correspondent registers.
	MOVQ	0(SI), CX
	MOVQ	8(SI), DX
	MOVQ	16(SI), R8
	MOVQ	24(SI), R9
	// Floating point arguments are passed in the XMM
	// registers. Set them here in case any of the arguments
	// are floating point values. For details see
	//	https://msdn.microsoft.com/en-us/library/zthk2dkh.aspx
	MOVQ	CX, X0
	MOVQ	DX, X1
	MOVQ	R8, X2
	MOVQ	R9, X3

	// Call stdcall function.
	CALL	AX

	ADDQ	$(maxargs*8), SP

	// Return result.
	POPQ	CX
	MOVQ	AX, libcall_r1(CX)
	// Floating point return values are returned in XMM0. Setting r2 to this
	// value in case this call returned a floating point value. For details,
	// see https://docs.microsoft.com/en-us/cpp/build/x64-calling-convention
	MOVQ    X0, libcall_r2(CX)

	// GetLastError().
	MOVQ	0x30(GS), DI
	MOVL	0x68(DI), AX
	MOVQ	AX, libcall_err(CX)

	RET

TEXT runtime·badsignal2(SB),NOSPLIT|NOFRAME,$48
	// stderr
	MOVQ	$-12, CX // stderr
	MOVQ	CX, 0(SP)
	MOVQ	runtime·_GetStdHandle(SB), AX
	CALL	AX

	MOVQ	AX, CX	// handle
	MOVQ	CX, 0(SP)
	MOVQ	$runtime·badsignalmsg(SB), DX // pointer
	MOVQ	DX, 8(SP)
	MOVL	$runtime·badsignallen(SB), R8 // count
	MOVQ	R8, 16(SP)
	LEAQ	40(SP), R9  // written count
	MOVQ	$0, 0(R9)
	MOVQ	R9, 24(SP)
	MOVQ	$0, 32(SP)	// overlapped
	MOVQ	runtime·_WriteFile(SB), AX
	CALL	AX

	RET

// faster get/set last error
TEXT runtime·getlasterror(SB),NOSPLIT,$0
	MOVQ	0x30(GS), AX
	MOVL	0x68(AX), AX
	MOVL	AX, ret+0(FP)
	RET

// Called by Windows as a Vectored Exception Handler (VEH).
// First argument is pointer to struct containing
// exception record and context pointers.
// Handler function is stored in AX.
// Return 0 for 'not handled', -1 for handled.
TEXT sigtramp<>(SB),NOSPLIT|NOFRAME,$0-0
	// CX: PEXCEPTION_POINTERS ExceptionInfo

	// DI SI BP BX R12 R13 R14 R15 registers and DF flag are preserved
	// as required by windows callback convention.
	PUSHFQ
	SUBQ	$112, SP
	MOVQ	DI, 80(SP)
	MOVQ	SI, 72(SP)
	MOVQ	BP, 64(SP)
	MOVQ	BX, 56(SP)
	MOVQ	R12, 48(SP)
	MOVQ	R13, 40(SP)
	MOVQ	R14, 32(SP)
	MOVQ	R15, 88(SP)

	MOVQ	AX, R15	// save handler address

	// find g
	get_tls(DX)
	CMPQ	DX, $0
	JNE	3(PC)
	MOVQ	$0, AX // continue
	JMP	done
	MOVQ	g(DX), DX
	CMPQ	DX, $0
	JNE	2(PC)
	CALL	runtime·badsignal2(SB)

	// save g and SP in case of stack switch
	MOVQ	DX, 96(SP) // g
	MOVQ	SP, 104(SP)

	// do we need to switch to the g0 stack?
	MOVQ	g_m(DX), BX
	MOVQ	m_g0(BX), BX
	CMPQ	DX, BX
	JEQ	g0

	// switch to g0 stack
	get_tls(BP)
	MOVQ	BX, g(BP)
	MOVQ	(g_sched+gobuf_sp)(BX), DI
	// make room for sighandler arguments
	// and re-save old SP for restoring later.
	// (note that the 104(DI) here must match the 104(SP) above.)
	SUBQ	$120, DI
	MOVQ	SP, 104(DI)
	MOVQ	DI, SP

g0:
	MOVQ	0(CX), BX // ExceptionRecord*
	MOVQ	8(CX), CX // Context*
	MOVQ	BX, 0(SP)
	MOVQ	CX, 8(SP)
	MOVQ	DX, 16(SP)
	CALL	R15	// call handler
	// AX is set to report result back to Windows
	MOVL	24(SP), AX

	// switch back to original stack and g
	// no-op if we never left.
	MOVQ	104(SP), SP
	MOVQ	96(SP), DX
	get_tls(BP)
	MOVQ	DX, g(BP)

done:
	// restore registers as required for windows callback
	MOVQ	88(SP), R15
	MOVQ	32(SP), R14
	MOVQ	40(SP), R13
	MOVQ	48(SP), R12
	MOVQ	56(SP), BX
	MOVQ	64(SP), BP
	MOVQ	72(SP), SI
	MOVQ	80(SP), DI
	ADDQ	$112, SP
	POPFQ

	RET

TEXT runtime·exceptiontramp<ABIInternal>(SB),NOSPLIT|NOFRAME,$0
	MOVQ	$runtime·exceptionhandler(SB), AX
	JMP	sigtramp<>(SB)

TEXT runtime·firstcontinuetramp<ABIInternal>(SB),NOSPLIT|NOFRAME,$0-0
	MOVQ	$runtime·firstcontinuehandler(SB), AX
	JMP	sigtramp<>(SB)

TEXT runtime·lastcontinuetramp<ABIInternal>(SB),NOSPLIT|NOFRAME,$0-0
	MOVQ	$runtime·lastcontinuehandler(SB), AX
	JMP	sigtramp<>(SB)

GLOBL runtime·cbctxts(SB), NOPTR, $8

TEXT runtime·callbackasm1(SB),NOSPLIT,$0
	// Construct args vector for cgocallback().
	// By windows/amd64 calling convention first 4 args are in CX, DX, R8, R9
	// args from the 5th on are on the stack.
	// In any case, even if function has 0,1,2,3,4 args, there is reserved
	// but uninitialized "shadow space" for the first 4 args.
	// The values are in registers.
  	MOVQ	CX, (16+0)(SP)
  	MOVQ	DX, (16+8)(SP)
  	MOVQ	R8, (16+16)(SP)
  	MOVQ	R9, (16+24)(SP)
	// R8 = address of args vector
	LEAQ	(16+0)(SP), R8

	// remove return address from stack, we are not returning to callbackasm, but to its caller.
  	MOVQ	0(SP), AX
	ADDQ	$8, SP

	// determine index into runtime·cbs table
	MOVQ	$runtime·callbackasm<ABIInternal>(SB), DX
	SUBQ	DX, AX
	MOVQ	$0, DX
	MOVQ	$5, CX	// divide by 5 because each call instruction in runtime·callbacks is 5 bytes long
	DIVL	CX
	SUBQ	$1, AX	// subtract 1 because return PC is to the next slot

	// DI SI BP BX R12 R13 R14 R15 registers and DF flag are preserved
	// as required by windows callback convention.
	PUSHFQ
	SUBQ	$64, SP
	MOVQ	DI, 56(SP)
	MOVQ	SI, 48(SP)
	MOVQ	BP, 40(SP)
	MOVQ	BX, 32(SP)
	MOVQ	R12, 24(SP)
	MOVQ	R13, 16(SP)
	MOVQ	R14, 8(SP)
	MOVQ	R15, 0(SP)

	// Go ABI requires DF flag to be cleared.
	CLD

	// Create a struct callbackArgs on our stack to be passed as
	// the "frame" to cgocallback and on to callbackWrap.
	SUBQ	$(24+callbackArgs__size), SP
	MOVQ	AX, (24+callbackArgs_index)(SP) 	// callback index
	MOVQ	R8, (24+callbackArgs_args)(SP)  	// address of args vector
	MOVQ	$0, (24+callbackArgs_result)(SP)	// result
	LEAQ	24(SP), AX
	// Call cgocallback, which will call callbackWrap(frame).
	MOVQ	$0, 16(SP)	// context
	MOVQ	AX, 8(SP)	// frame (address of callbackArgs)
	LEAQ	·callbackWrap<ABIInternal>(SB), BX	// cgocallback takes an ABIInternal entry-point
	MOVQ	BX, 0(SP)	// PC of function value to call (callbackWrap)
	CALL	·cgocallback(SB)
	// Get callback result.
	MOVQ	(24+callbackArgs_result)(SP), AX
	ADDQ	$(24+callbackArgs__size), SP

	// restore registers as required for windows callback
	MOVQ	0(SP), R15
	MOVQ	8(SP), R14
	MOVQ	16(SP), R13
	MOVQ	24(SP), R12
	MOVQ	32(SP), BX
	MOVQ	40(SP), BP
	MOVQ	48(SP), SI
	MOVQ	56(SP), DI
	ADDQ	$64, SP
	POPFQ

	// The return value was placed in AX above.
	RET

// uint32 tstart_stdcall(M *newm);
TEXT runtime·tstart_stdcall<ABIInternal>(SB),NOSPLIT,$0
	// CX contains first arg newm
	MOVQ	m_g0(CX), DX		// g

	// Layout new m scheduler stack on os stack.
	MOVQ	SP, AX
	MOVQ	AX, (g_stack+stack_hi)(DX)
	SUBQ	$(64*1024), AX		// initial stack size (adjusted later)
	MOVQ	AX, (g_stack+stack_lo)(DX)
	ADDQ	$const__StackGuard, AX
	MOVQ	AX, g_stackguard0(DX)
	MOVQ	AX, g_stackguard1(DX)

	// Set up tls.
	LEAQ	m_tls(CX), SI
	MOVQ	SI, 0x28(GS)
	MOVQ	CX, g_m(DX)
	MOVQ	DX, g(SI)

	// Someday the convention will be D is always cleared.
	CLD

	CALL	runtime·stackcheck(SB)	// clobbers AX,CX
	CALL	runtime·mstart(SB)

	XORL	AX, AX			// return 0 == success
	RET

// set tls base to DI
TEXT runtime·settls(SB),NOSPLIT,$0
	MOVQ	DI, 0x28(GS)
	RET

// Runs on OS stack.
// duration (in -100ns units) is in dt+0(FP).
// g may be nil.
// The function leaves room for 4 syscall parameters
// (as per windows amd64 calling convention).
TEXT runtime·usleep2(SB),NOSPLIT|NOFRAME,$48-4
	MOVLQSX	dt+0(FP), BX
	MOVQ	SP, AX
	ANDQ	$~15, SP	// alignment as per Windows requirement
	MOVQ	AX, 40(SP)
	LEAQ	32(SP), R8  // ptime
	MOVQ	BX, (R8)
	MOVQ	$-1, CX // handle
	MOVQ	$0, DX // alertable
	MOVQ	runtime·_NtWaitForSingleObject(SB), AX
	CALL	AX
	MOVQ	40(SP), SP
	RET

// Runs on OS stack. duration (in -100ns units) is in dt+0(FP).
// g is valid.
TEXT runtime·usleep2HighRes(SB),NOSPLIT|NOFRAME,$72-4
	MOVLQSX	dt+0(FP), BX
	get_tls(CX)

	MOVQ	SP, AX
	ANDQ	$~15, SP	// alignment as per Windows requirement
	MOVQ	AX, 64(SP)

	MOVQ	g(CX), CX
	MOVQ	g_m(CX), CX
	MOVQ	(m_mOS+mOS_highResTimer)(CX), CX	// hTimer
	MOVQ	CX, 48(SP)				// save hTimer for later
	LEAQ	56(SP), DX				// lpDueTime
	MOVQ	BX, (DX)
	MOVQ	$0, R8					// lPeriod
	MOVQ	$0, R9					// pfnCompletionRoutine
	MOVQ	$0, AX
	MOVQ	AX, 32(SP)				// lpArgToCompletionRoutine
	MOVQ	AX, 40(SP)				// fResume
	MOVQ	runtime·_SetWaitableTimer(SB), AX
	CALL	AX

	MOVQ	48(SP), CX				// handle
	MOVQ	$0, DX					// alertable
	MOVQ	$0, R8					// ptime
	MOVQ	runtime·_NtWaitForSingleObject(SB), AX
	CALL	AX

	MOVQ	64(SP), SP
	RET

// Runs on OS stack.
TEXT runtime·switchtothread(SB),NOSPLIT|NOFRAME,$0
	MOVQ	SP, AX
	ANDQ	$~15, SP	// alignment as per Windows requirement
	SUBQ	$(48), SP	// room for SP and 4 args as per Windows requirement
				// plus one extra word to keep stack 16 bytes aligned
	MOVQ	AX, 32(SP)
	MOVQ	runtime·_SwitchToThread(SB), AX
	CALL	AX
	MOVQ	32(SP), SP
	RET

// See https://wrkhpi.wordpress.com/2007/08/09/getting-os-information-the-kuser_shared_data-structure/
// Archived copy at:
// http://web.archive.org/web/20210411000829/https://wrkhpi.wordpress.com/2007/08/09/getting-os-information-the-kuser_shared_data-structure/
// Must read hi1, then lo, then hi2. The snapshot is valid if hi1 == hi2.
#define _INTERRUPT_TIME 0x7ffe0008
#define _SYSTEM_TIME 0x7ffe0014
#define time_lo 0
#define time_hi1 4
#define time_hi2 8

TEXT runtime·nanotime1(SB),NOSPLIT,$0-8
	CMPB	runtime·useQPCTime(SB), $0
	JNE	useQPC
	MOVQ	$_INTERRUPT_TIME, DI
loop:
	MOVL	time_hi1(DI), AX
	MOVL	time_lo(DI), BX
	MOVL	time_hi2(DI), CX
	CMPL	AX, CX
	JNE	loop
	SHLQ	$32, CX
	ORQ	BX, CX
	IMULQ	$100, CX
	MOVQ	CX, ret+0(FP)
	RET
useQPC:
	// Call with ABIInternal because we could be
	// very deep in a nosplit context and the wrapper
	// adds stack space.
	// TODO(#40724): The result from nanotimeQPC will
	// be passed in a register, so store that to the
	// stack so we can return through a wrapper.
	JMP	runtime·nanotimeQPC<ABIInternal>(SB)
	RET

TEXT time·now(SB),NOSPLIT,$0-24
	CMPB	runtime·useQPCTime(SB), $0
	JNE	useQPC
	MOVQ	$_INTERRUPT_TIME, DI
loop:
	MOVL	time_hi1(DI), AX
	MOVL	time_lo(DI), BX
	MOVL	time_hi2(DI), CX
	CMPL	AX, CX
	JNE	loop
	SHLQ	$32, AX
	ORQ	BX, AX
	IMULQ	$100, AX
	MOVQ	AX, mono+16(FP)

	MOVQ	$_SYSTEM_TIME, DI
wall:
	MOVL	time_hi1(DI), AX
	MOVL	time_lo(DI), BX
	MOVL	time_hi2(DI), CX
	CMPL	AX, CX
	JNE	wall
	SHLQ	$32, AX
	ORQ	BX, AX
	MOVQ	$116444736000000000, DI
	SUBQ	DI, AX
	IMULQ	$100, AX

	// generated code for
	//	func f(x uint64) (uint64, uint64) { return x/1000000000, x%100000000 }
	// adapted to reduce duplication
	MOVQ	AX, CX
	MOVQ	$1360296554856532783, AX
	MULQ	CX
	ADDQ	CX, DX
	RCRQ	$1, DX
	SHRQ	$29, DX
	MOVQ	DX, sec+0(FP)
	IMULQ	$1000000000, DX
	SUBQ	DX, CX
	MOVL	CX, nsec+8(FP)
	RET
useQPC:
	JMP	runtime·nowQPC(SB)
	RET

// func osSetupTLS(mp *m)
// Setup TLS. for use by needm on Windows.
TEXT runtime·osSetupTLS(SB),NOSPLIT,$0-8
	MOVQ	mp+0(FP), AX
	LEAQ	m_tls(AX), DI
	CALL	runtime·settls(SB)
	RET
