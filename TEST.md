# Testing the debug build on the phone

Nothing here replaces the installed Termux `mesa` / `mesa-vulkan-icd-freedreno`.
The test driver lives in `$PREFIX/opt/tmd/<variant>/` and is only used by
processes started with `VK_ICD_FILENAMES` pointing at its JSON. **Do not**
`apt install` / `dpkg -i` the `.deb` artifacts; they have the same version as
the system packages and would replace them.

Variants (one artifact each):

| artifact | contents |
|---|---|
| `tmd-vulkan-debug` | Turnip with logging only (`patches/9000-tmd-debug-wsi-fences.patch`) |
| `tmd-vulkan-fix`   | logging + `patches/fix-9100-kgsl-syncobj-merge.patch` |
| `mesa-debs-debug`, `mesa-debs-fix` | full set of .debs (reference only, do not install) |

## 1. Download and unpack

```sh
pkg install gh            # once; then: gh auth login
mkdir -p $PREFIX/opt/tmd && cd $PREFIX/tmp
# latest green run (known good: 42209597343)
RUN=$(gh run list -R n2ray/termux-mesa-debug -w build-mesa -s success -L 1 --json databaseId -q '.[0].databaseId')
echo "run: $RUN"
rm -rf tmd-dl && mkdir tmd-dl
gh run download "$RUN" -R n2ray/termux-mesa-debug -n tmd-vulkan-debug -D tmd-dl
gh run download "$RUN" -R n2ray/termux-mesa-debug -n tmd-vulkan-fix   -D tmd-dl
for t in tmd-dl/*.tar.gz; do tar -xzf "$t" -C $PREFIX/opt/tmd/; done
ls -l $PREFIX/opt/tmd/*/
cat $PREFIX/opt/tmd/debug/freedreno_icd.json   # library_path must be $PREFIX/opt/tmd/debug/libvulkan_freedreno.so
```

Quick check that the right driver is picked up (`vulkaninfo` is in package `vulkan-tools`):

```sh
pkg install vulkan-tools   # provides vulkaninfo and vkcube
VK_ICD_FILENAMES=$PREFIX/opt/tmd/debug/freedreno_icd.json TMD_DEBUG=1 vulkaninfo --summary 2>&1 | head -40
```

## 2. Run a client

Start your X server as usual (DISPLAY=:1 below). Use a fresh log each run.

```sh
export DISPLAY=:1
ICD=$PREFIX/opt/tmd/debug/freedreno_icd.json      # or .../fix/freedreno_icd.json
LOG=$PREFIX/tmp/tmd.log
rm -f $LOG
```

### a) vkcube (simplest, ~30 s)

```sh
VK_ICD_FILENAMES=$ICD TMD_DEBUG=1 TMD_LOG=$LOG timeout 30 vkcube --wsi xcb 2>&1 | grep -v '^$' | tail -5
```

### b) Chromium (ANGLE on Vulkan)

```sh
VK_ICD_FILENAMES=$ICD TMD_DEBUG=1 TMD_LOG=$LOG \
  chromium --use-angle=vulkan --enable-features=Vulkan --user-data-dir=$PREFIX/tmp/chromium-tmd \
  https://webglsamples.org/aquarium/aquarium.html
```

(Chromium's GPU process inherits the environment; its lines also land in
`$LOG` because every process appends to `TMD_LOG`. `pid=` tells processes apart.)

### c) Run each client three times

1. default (FIFO): as above
2. `MESA_VK_WSI_PRESENT_MODE=mailbox` added
3. `TMD_FORCE_FENCE_WAIT=1` added (Mesa then waits on the CPU until the GPU
   has finished the frame before it sends PresentPixmap, in every present mode)

For each run write down: tearing yes/no/less, and the X server's
`dma-buf fences:` line (`logcat -s LorieNative` in another shell, every 5 s).

## 3. Send back

```sh
grep -c . $LOG; head -c 200000 $LOG > $PREFIX/tmp/tmd-send.log
logcat -d -s LorieNative | tail -50 >> $PREFIX/tmp/tmd-send.log
```

Send `tmd-send.log` plus your notes from 2c. It contains PIDs, sizes and fd
numbers only.

## 4. What the lines mean

Every line starts with `TMD <monotonic-seconds> pid=<pid>:`.

**Self-test** (once per process):

```
wsi selftest dma-buf sync_file import/export: PASS (vk=0) step='ok' ...
```
* `PASS`: Mesa will attach a fence on every present (hypothesis H2 is ruled out).
* `FAIL ... step='DMA_BUF_IOCTL_IMPORT_SYNC_FILE' errno=25(...)`: the kernel or
  the dma-heap rejects the ioctl; Mesa then attaches nothing. `step` names the
  failing call: `GetMemoryFdKHR==NULL` (software WSI), `semaphore SYNC_FD not
  exportable`, `AllocateMemory(...)`, `GetMemoryFdKHR(DMA_BUF)`,
  `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`, `DMA_BUF_IOCTL_IMPORT_SYNC_FILE`.

**Per swapchain:**

```
swapchain 0x..: CreateSemaphore(export SYNC_FD) vk=0 dma_buf_semaphore=yes
x11 swapchain 0x..: 1080x2400 images=3 sw=0 dri3=1 dri3_modifiers=1 dri3_explicit_sync=0 present_caps=0x.. xwayland=0 mit_shm=1 same_gpu=1 present_mode=2 wsi_cpu_waits_fence_before_PresentPixmap=0 TMD_FORCE_FENCE_WAIT=0
```
* `dma_buf_semaphore=NULL` / `selftest failed -> NO dma_buf_semaphore`: no fence will ever be attached.
* `explicit sync (DRI3 syncobj)`: the server advertised DRI3 syncobj; fences go through syncobjs, not the dma-buf.
* `xwayland=1`: Mesa thinks the server is Xwayland; then MAILBOX does **not**
  wait for the fence (explains why the mailbox test did not help).
* `wsi_cpu_waits_fence_before_PresentPixmap=1`: in this mode (MAILBOX on non-Xwayland)
  the frame is finished before the server ever sees it, so the server seeing
  only stub fences is expected and correct.
* `same_gpu=0`: prime path (Turnip renders to a tiled image and blits to a linear buffer).
* `present_mode`: 0 IMMEDIATE, 1 MAILBOX, 2 FIFO, 3 FIFO_RELAXED.

**Per present** (first 20, then every 300th):

```
present #12 chain=0x.. img=1 path=native dma_buf_fd=57 modifier=0x0 explicit_sync=0 dma_buf_semaphore=yes present_mode=2 blit_queue=same
  semaphore->SYNC_FD fd=88 PENDING n=1 [kgsl-timeline/...:pending] | IMPORT_SYNC_FILE on dma_buf_fd=57: vk=0 errno=0(-) | dma-buf now: PENDING n=1 [kgsl...:pending]
```
* `path=`: `native` (render target is the presented dma-buf), `prime(buffer-blit)`
  (GPU blit into a linear dma-buf), `cpu/sw` (software, no dma-buf).
* `semaphore->SYNC_FD fd=-1` / `none(fd=-1)`: the kgsl semaphore had no fence to
  export; the import then fails with EINVAL.
* `IMPORT_SYNC_FILE ... vk=0 errno=0`: the import worked.
* `dma-buf now: PENDING`: right after the import the dma-buf carries an
  unfinished GPU fence. If the server still reports "found no fence" for the
  same frames, it checks too late (the fence signalled in between) or checks a
  different buffer.
* `dma-buf now: signaled n=1 [stub...]`: the GPU had already finished the frame
  when Mesa attached the fence (the kernel drops signalled fences). Normal with
  mailbox/forced wait or light load.
* `semaphore->SYNC_FD export FAILED`: the semaphore could not be exported.

**kgsl:**
```
kgsl IOCTL_KGSL_TIMESTAMP_EVENT(ts=..) failed #1: errno=...
```
The kernel refused to make a fence from a GPU timestamp; Turnip then treats the
fence as already signalled, so nothing waits on that frame.

## 5. How to read the combination

| TMD log | `TMD_FORCE_FENCE_WAIT=1` tearing | conclusion |
|---|---|---|
| selftest FAIL / semaphore NULL | gone | fence never attached: H2, fix in Mesa (see NOTES.md) |
| import OK, `dma-buf now: PENDING` often | gone | fences are attached; the server checks after they signalled or does not wait long enough |
| import OK | **still tears** | not a render-fence problem: the server reads a buffer the client is already rendering into again (idle/release signalled before the copy finished) or reads stale CPU cache lines (no `DMA_BUF_IOCTL_SYNC` around the CPU read) — see NOTES.md H1 |
| `kgsl ... TIMESTAMP_EVENT failed` lines | — | kgsl fence creation broken on this kernel |

If anything unexpected happens (no `TMD` lines at all), check that
`VK_ICD_FILENAMES` points at the tmd JSON and that `TMD_DEBUG=1` (exactly `1`).
