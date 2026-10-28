; The ROM's version, shown on the status row at power-on (item VER, owner F22).
; Edit at each release; not generated from git, so that a build stays reproducible (make repro).
; At most 19 characters (V2_STATUS_BUF holds 20 bytes with the terminator).
V2_VERSION_TEXT: DB "2068 LEAP V2.1",0
