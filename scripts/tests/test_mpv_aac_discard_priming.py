"""Exercise the supplemental patch's actual discarded-frame bookkeeping block.

The pinned decoder/runtime regression is retained separately in provenance. This
portable harness covers side-data boundaries and residual skip budgets without
requiring the external MPVKit static products on every test machine.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AACDiscardPrimingTests(unittest.TestCase):
    def test_discarded_priming_bookkeeping(self):
        patch = (ROOT / 'docs/dependency-patches/mpv-0.41.0-aac-discard-priming.patch').read_text()
        block = '\n'.join(line[1:] for line in patch.splitlines()
                          if line[:1] in ('+', ' ') and not line.startswith('+++'))
        block = block[block.index('    if (priv->avframe->flags'):block.index('    if (!priv->avframe->buf[0])')]
        source = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#define AV_FRAME_FLAG_DISCARD 4
#define AV_FRAME_DATA_SKIP_SAMPLES 1
#define MPMIN(a,b) ((a)<(b)?(a):(b))
#define AV_RL32(p) (*(const uint32_t *)(p))
typedef struct { int size; unsigned char *data; } AVFrameSideData;
struct frame { int flags, nb_samples; AVFrameSideData *sd; bool unreferenced; };
struct priv { struct frame *avframe; bool preroll_done; uint32_t skip_samples; };
static AVFrameSideData *av_frame_get_side_data(struct frame *f, int type)
{ (void)type; return f->sd; }
static void av_frame_unref(struct frame *f) { f->unreferenced = true; }
static void apply(struct priv *priv) {
''' + block + r'''
}
int main(void) {
    uint32_t data[3] = {1024, 0, 0};
    AVFrameSideData sd = {10, (unsigned char *)data};
    struct frame f = {4, 1024, &sd, false};
    struct priv p = {&f, false, 0};
    apply(&p); assert(f.unreferenced && p.preroll_done && p.skip_samples == 0);
    p.preroll_done = false; data[0] = 2048;
    apply(&p); assert(p.preroll_done && p.skip_samples == 1024);
    f.sd = NULL;
    apply(&p); assert(p.skip_samples == 0); /* residual consumed by next discard */
    f.sd = &sd; data[0] = 4096;
    apply(&p); assert(p.skip_samples == 0); /* later side data leaves initial state unchanged */
    p.preroll_done = false; p.skip_samples = 0; data[0] = 0;
    apply(&p); assert(!p.preroll_done && p.skip_samples == 0);
    data[0] = 1024; sd.size = 9;
    apply(&p); assert(!p.preroll_done && p.skip_samples == 0);
    sd.size = 10; f.sd = NULL;
    apply(&p); assert(!p.preroll_done && p.skip_samples == 0);
    f.sd = &sd; f.flags = 0; f.unreferenced = false;
    apply(&p); assert(!f.unreferenced && !p.preroll_done && p.skip_samples == 0);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'test.c').write_text(source)
            subprocess.run([shutil.which('clang') or 'clang', '-std=c11', '-Wall', '-Wextra',
                            '-Werror', '-fsanitize=address,undefined',
                            '-fno-sanitize-recover=all', str(path / 'test.c'),
                            '-o', str(path / 'test')], check=True, capture_output=True, timeout=60)
            subprocess.run([str(path / 'test')], check=True, capture_output=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
