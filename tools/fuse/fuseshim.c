/* Copied unchanged from 2068-Leap-C (MIT, tools/fuse/fuseshim.c) for V2's Fuse probes
   (tools/qual/fuse_frames_probe.py; docs/V2_LEAPC_BACKPORT_PLAN.md item 0.8). The LEAPC_* environment
   names are kept so the two copies stay identical apart from this note. */
/* tools/fuse/fuseshim.c -- remote control for Fuse 1.9.1 (SDL2 UI) in the Leap-C tests (Phase 9).

   An LD_PRELOAD library: Fuse calls SDL_PollEvent once per emulated frame (ui_event, from the frame
   event), so this SDL_PollEvent does the harness's work there, in Fuse's own thread between two frames,
   then lets SDL's run. Commands arrive as lines on a Unix socket (LEAPC_FUSE_SOCK; "@name": an abstract
   one) and each gets one
   reply line. It drives Fuse only through Fuse's own entry points: the keyboard matrix
   (keyboard_press / keyboard_release, the half-row bits the emulated port $FE returns), the debugger's
   command interpreter (debugger_command_evaluate: breakpoints, their commands, `set`, `print`), the
   tape deck (tape_open, tape_record_start / _stop, tape_write) and the memory map for reading.
   tools/fusetest.py takes their addresses from `nm` of the Fuse binary (it is not stripped) and passes
   them as offsets from the load address (LEAPC_FUSE_SYMS "name=hex,..."), with sizeof(memory_page)
   checked against the symbol table there.

   Commands (A, N decimal or 0x hex; K a Fuse keyboard_key_name number):
     ping                        -> "ok FRAMES TSTATES"       (frames since reset, T-states in the frame)
     press K / release K         -> "ok"                      a key down or up now
     chords ACC LO HI C1 C2 ...  -> "ok"                      queue chords (keys joined by '+'), typed
                                    one at a time: each pressed once the machine waits for a key (the
                                    PC, or at a frame's interrupt the PC it interrupted, in [LO, HI):
                                    the key wait's loop) and the last release has been seen for two
                                    frames; held until the byte at ACC changes (a debugger breakpoint
                                    counts the key acceptances there); then released
     queue                       -> "ok N W"                  chords not typed yet (0: done); W 1 if
                                                              the machine waits for a key now
     peek A N                    -> "ok HEX"                  N bytes as mapped now (no contention)
     poke A HEX                  -> "ok"                      bytes written as mapped (writebyte_internal)
     dbg TEXT                    -> "ok"                      a debugger command ("\n" for a newline);
                                                              its output goes to Fuse's standard output
     tape_open PATH / tape_write PATH / tape_rec_start / tape_rec_stop / tape_playing / tape_toggle
                                 -> "ok RESULT"
     quit                        -> exits Fuse at once (exit status 0)
   A Fuse dialog opened by a command (an error: a tape it cannot read) runs its own loop, which polls here
   again: those polls answer it with Return, so the command ends and replies (with Fuse's error code).
*/
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <SDL2/SDL.h>

typedef struct memory_page {            /* Fuse's memory_pages.h (1.9.1) */
  uint8_t *page;
  int writable, contended, source, save_to_snapshot, page_num;
  uint16_t offset;
} memory_page;
#define PAGE_LOG 11

static int (*real_poll)(SDL_Event *);
static uintptr_t base;
static memory_page *map_read;
static uint8_t *cpu;                    /* Fuse's z80 (z80/z80.h processor): SP at 26, PC at 28 */
static uint32_t *frames_p, *tstates_p;
static void (*k_press)(int), (*k_release)(int);
static int (*dbg_eval)(const char *);
static void (*poke_fn)(uint16_t, uint8_t);
static int (*f_tape_open)(const char *, int), (*f_tape_write)(const char *);
static int (*f_rec_start)(void), (*f_rec_stop)(void), (*f_tape_playing)(void), (*f_tape_toggle)(int);

static int lsock = -1, csock = -1;
static int in_command, nested;          /* a dialog's loop polling while a command runs (re-entry) */
static char inbuf[1 << 16];
static size_t inlen;

#define MAXCH 8192
static int chord[MAXCH][4], chord_n[MAXCH], nchords, cur;
static int st;                          /* 0 idle/next, 1 held, 2 released: waiting for the key wait */
static uint16_t acc_addr, wait_lo, wait_hi;
static uint8_t acc0;
static uint32_t rel_frame;

static int phdr_cb(struct dl_phdr_info *info, size_t size, void *data)
{
  (void)size; (void)data;
  base = info->dlpi_addr;               /* the first object is the executable */
  return 1;
}

static void *sym(const char *name)
{
  const char *s = getenv("LEAPC_FUSE_SYMS"), *p;
  size_t n = strlen(name);
  for (p = s; p && *p; ) {
    if (!strncmp(p, name, n) && p[n] == '=')
      return (void *)(base + strtoull(p + n + 1, NULL, 16));
    p = strchr(p, ',');
    if (p) p++;
  }
  fprintf(stderr, "fuseshim: no symbol %s\n", name);
  exit(3);
}

static uint8_t rd(uint16_t a)
{
  return map_read[a >> PAGE_LOG].page[a & ((1 << PAGE_LOG) - 1)];
}

static void init(void)
{
  struct sockaddr_un sa;
  const char *path = getenv("LEAPC_FUSE_SOCK");
  real_poll = dlsym(RTLD_NEXT, "SDL_PollEvent");
  dl_iterate_phdr(phdr_cb, NULL);
  map_read = sym("memory_map_read");
  cpu = sym("z80");
  frames_p = sym("frames_since_reset");
  tstates_p = sym("tstates");
  k_press = sym("keyboard_press");
  k_release = sym("keyboard_release");
  dbg_eval = sym("debugger_command_evaluate");
  poke_fn = sym("writebyte_internal");
  f_tape_open = sym("tape_open");
  f_tape_write = sym("tape_write");
  f_rec_start = sym("tape_record_start");
  f_rec_stop = sym("tape_record_stop");
  f_tape_playing = sym("tape_is_playing");
  f_tape_toggle = sym("tape_toggle_play");
  if (!path) { fprintf(stderr, "fuseshim: LEAPC_FUSE_SOCK not set\n"); exit(3); }
  lsock = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
  memset(&sa, 0, sizeof sa);
  sa.sun_family = AF_UNIX;
  strncpy(sa.sun_path, path, sizeof sa.sun_path - 1);
  if (path[0] == '@') sa.sun_path[0] = 0; /* "@name": Linux's abstract namespace */
  else unlink(path);
  if (bind(lsock, (struct sockaddr *)&sa, offsetof(struct sockaddr_un, sun_path) + strlen(path)) || listen(lsock, 1)) {
    perror("fuseshim: socket");
    exit(3);
  }
}

static void reply(const char *s)
{
  size_t n = strlen(s), o = 0;
  while (o < n) {
    ssize_t w = write(csock, s + o, n - o);
    if (w < 0) { if (errno == EAGAIN || errno == EINTR) continue; return; }
    o += (size_t)w;
  }
  if (write(csock, "\n", 1) < 0) return;
}

static void chord_keys(int i, void (*fn)(int))
{
  int k;
  for (k = 0; k < chord_n[i]; k++) fn(chord[i][k]);
}

static int at_key_wait(void)
{
  uint16_t pc = (uint16_t)(cpu[28] | cpu[29] << 8), sp = (uint16_t)(cpu[26] | cpu[27] << 8);
  if (pc == 0x0038)                     /* the frame's interrupt was just accepted: where it came from */
    pc = (uint16_t)(rd(sp) | rd((uint16_t)(sp + 1)) << 8);
  return pc >= wait_lo && pc < wait_hi;
}

static void typist(void)               /* once per frame */
{
  if (cur >= nchords) return;
  if (st == 0) {
    if (*frames_p < rel_frame + 2 || !at_key_wait()) return;
    acc0 = rd(acc_addr);
    chord_keys(cur, k_press);
    st = 1;
  } else if (rd(acc_addr) != acc0) {
    chord_keys(cur, k_release);
    rel_frame = *frames_p;
    cur++;
    st = 0;
  }
}

static void command(char *line)
{
  static char out[1 << 17];
  char *arg = strchr(line, ' ');
  if (arg) *arg++ = 0; else arg = line + strlen(line);
  if (!strcmp(line, "ping")) {
    snprintf(out, sizeof out, "ok %u %u", *frames_p, *tstates_p);
    reply(out);
  } else if (!strcmp(line, "press") || !strcmp(line, "release")) {
    (line[0] == 'p' ? k_press : k_release)((int)strtol(arg, NULL, 0));
    reply("ok");
  } else if (!strcmp(line, "chords")) {
    char *tok, *save;
    acc_addr = (uint16_t)strtol(strtok_r(arg, " ", &save), NULL, 0);
    wait_lo = (uint16_t)strtol(strtok_r(NULL, " ", &save), NULL, 0);
    wait_hi = (uint16_t)strtol(strtok_r(NULL, " ", &save), NULL, 0);
    if (cur >= nchords) { nchords = cur = 0; st = 0; }
    while ((tok = strtok_r(NULL, " ", &save)) && nchords < MAXCH) {
      char *s2, *k;
      chord_n[nchords] = 0;
      for (k = strtok_r(tok, "+", &s2); k && chord_n[nchords] < 4; k = strtok_r(NULL, "+", &s2))
        chord[nchords][chord_n[nchords]++] = (int)strtol(k, NULL, 0);
      nchords++;
    }
    reply("ok");
  } else if (!strcmp(line, "queue")) {
    snprintf(out, sizeof out, "ok %d %d", nchords - cur, at_key_wait());
    reply(out);
  } else if (!strcmp(line, "peek")) {
    char *save;
    unsigned a = (unsigned)strtol(strtok_r(arg, " ", &save), NULL, 0);
    unsigned n = (unsigned)strtol(strtok_r(NULL, " ", &save), NULL, 0), i;
    if (n > 65536) n = 65536;
    strcpy(out, "ok ");
    for (i = 0; i < n && 3 + 2 * i + 2 < sizeof out; i++)
      sprintf(out + 3 + 2 * i, "%02x", rd((uint16_t)(a + i)));
    reply(out);
  } else if (!strcmp(line, "poke")) {
    char *save, *hex;
    unsigned a = (unsigned)strtol(strtok_r(arg, " ", &save), NULL, 0), i;
    hex = strtok_r(NULL, " ", &save);
    for (i = 0; hex && hex[2 * i] && hex[2 * i + 1]; i++) {
      char b[3] = { hex[2 * i], hex[2 * i + 1], 0 };
      poke_fn((uint16_t)(a + i), (uint8_t)strtol(b, NULL, 16));
    }
    reply("ok");
  } else if (!strcmp(line, "dbg")) {
    char *s, *d;
    for (s = d = arg; *s; s++, d++) {   /* "\n" -> newline */
      if (s[0] == '\\' && s[1] == 'n') { *d = '\n'; s++; } else *d = *s;
    }
    *d = 0;
    dbg_eval(arg);
    fflush(stdout);
    reply("ok");
  } else if (!strcmp(line, "tape_open")) {
    snprintf(out, sizeof out, "ok %d", f_tape_open(arg, 0)); reply(out);
  } else if (!strcmp(line, "tape_write")) {
    snprintf(out, sizeof out, "ok %d", f_tape_write(arg)); reply(out);
  } else if (!strcmp(line, "tape_rec_start")) {
    snprintf(out, sizeof out, "ok %d", f_rec_start()); reply(out);
  } else if (!strcmp(line, "tape_rec_stop")) {
    snprintf(out, sizeof out, "ok %d", f_rec_stop()); reply(out);
  } else if (!strcmp(line, "tape_playing")) {
    snprintf(out, sizeof out, "ok %d", f_tape_playing()); reply(out);
  } else if (!strcmp(line, "tape_toggle")) {
    snprintf(out, sizeof out, "ok %d", f_tape_toggle(0)); reply(out);
  } else if (!strcmp(line, "quit")) {
    fflush(stdout);
    _exit(0);
  } else {
    reply("error unknown command");
  }
}

static void service(void)
{
  if (csock < 0) {
    csock = accept4(lsock, NULL, NULL, SOCK_NONBLOCK);
    if (csock < 0) return;
  }
  for (;;) {
    ssize_t r = read(csock, inbuf + inlen, sizeof inbuf - 1 - inlen);
    char *nl;
    if (r == 0) { close(csock); csock = -1; inlen = 0; return; }
    if (r < 0) break;
    inlen += (size_t)r;
    inbuf[inlen] = 0;
    while ((nl = memchr(inbuf, '\n', inlen))) {
      size_t n = (size_t)(nl - inbuf) + 1;
      *nl = 0;
      command(inbuf);
      memmove(inbuf, inbuf + n, inlen - n);
      inlen -= n;
      inbuf[inlen] = 0;
    }
  }
}

int SDL_PollEvent(SDL_Event *e)
{
  if (!real_poll) init();
  fflush(stdout);                       /* the debugger's `print` lines reach the harness each frame */
  if (in_command) {                     /* a Fuse dialog (an error) inside a command: answer it with
                                           Return, down then up, so the command can end and reply */
    int phase = nested++ % 3;           /* down, up, then none: ui_event polls until none */
    if (phase == 2 || !e) return 0;
    memset(e, 0, sizeof *e);
    e->type = phase ? SDL_KEYUP : SDL_KEYDOWN;
    e->key.state = e->type == SDL_KEYDOWN ? SDL_PRESSED : SDL_RELEASED;
    e->key.keysym.sym = SDLK_RETURN;
    e->key.keysym.scancode = SDL_SCANCODE_RETURN;
    return 1;
  }
  typist();
  in_command = 1;
  service();
  in_command = 0;
  return real_poll(e);
}
