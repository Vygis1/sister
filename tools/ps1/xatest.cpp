// xatest.cpp - esp32/console/xa.h on the PC: raw 2352-byte sectors in (a file), the words the
// drive would get out (a file). tools/ps1/xatest.py builds and runs it and compares.
#include <stdio.h>
#include <stdlib.h>
#include "../../esp32/console/xa.h"
int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "xatest in.bin out.bin filtered\n"); return 2; }
  FILE *fi = fopen(argv[1], "rb"), *fo = fopen(argv[2], "wb");
  bool filtered = atoi(argv[3]) != 0;
  static uint8_t s[2352]; static uint32_t out[xa::MAX_OUT];
  xa::Decoder d; d.reset();
  long secs = 0, words = 0;
  while (fread(s, 1, 2352, fi) == 2352) {
    if (s[0] == 0xEE) { d.reset(); continue; }        // (a marker sector: the drive's flush)
    if (!d.accept(s, filtered)) continue;
    int n = d.decode(s, out);
    fwrite(out, 4, n, fo); secs++; words += n;
  }
  fclose(fo); fclose(fi);
  printf("%ld sectors, %ld words\n", secs, words);
  return 0;
}
