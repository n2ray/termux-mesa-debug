# Notes: render fences on Turnip/kgsl X11 presents (Termux mesa 26.2.6)

## Status

Last updated 2026-11-06. CI run with all artifacts:
https://github.com/n2ray/termux-mesa-debug/actions/runs/42209597343 (green).

**Verified (built):**
* `patches/9000-tmd-debug-wsi-fences.patch` and `patches/fix-9100-kgsl-syncobj-merge.patch`
  apply to pristine mesa-26.2.6 (sha256 checked) on top of all Termux patches (`patch-check` job).
* Termux's full `mesa` package for aarch64 builds with them, in Termux's docker builder at the
  termux-packages commit that is mesa 26.2.6 (`84f9775d`), about 11–17 min per variant. Artifacts:
  `tmd-vulkan-debug`, `tmd-vulkan-fix` (libvulkan_freedreno.so + side-by-side ICD json, ~2.4 MB),
  `mesa-debs-debug`, `mesa-debs-fix` (mesa + subpackage debs, reference only). The collect step
  checks that the TMD instrumentation strings are in the built .so and that the ICD json points to
  `$PREFIX/opt/tmd/<variant>/libvulkan_freedreno.so`.
* The same patches compile warning-free in a local x86-64 build of Turnip (kgsl) + X11 WSI.
* Not run on hardware: there is no phone here, so nothing about runtime behaviour is verified.

**Hypothesis (from reading the code, section 2–4):**
* On kgsl the fence-attach path is complete: the self-test uses dma-heap memory like the real
  images, the kgsl semaphore exports SYNC_FD, and `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` goes into the very
  dma-buf fd the X server receives. I found no step that silently skips the import.
* The kernel reports a fence that has already signalled as the stub fence, so the server's "100%
  stub" does not prove that no fence was attached. In MAILBOX mode Mesa CPU-waits for the GPU before
  PresentPixmap (`wsi_common_x11.c:2529`), and the phone still tore in MAILBOX mode.
* Most likely (H1): the tearing comes from the server side. Either it marks a buffer idle before its
  CPU copy is done, or the CPU reads without `DMA_BUF_IOCTL_SYNC` and gets stale cache lines.
  Alternatives H2–H5 are in section 4; the debug log decides between them.
* The fix patch corrects a real kgsl fence-merge bug, but nothing shows it causes the tearing.

**Next step for the person:** follow TEST.md. Run vkcube and Chromium with the `debug` driver three
ways: default, `MESA_VK_WSI_PRESENT_MODE=mailbox`, and `TMD_FORCE_FENCE_WAIT=1`. For each, note
whether it tears and the LorieNative `dma-buf fences:` line, and send `$PREFIX/tmp/tmd.log`. The
decisive lines are `wsi selftest ...`, `x11 swapchain ... xwayland= ...`, and the per-present
`IMPORT_SYNC_FILE ... | dma-buf now: ...`. If tearing persists with `TMD_FORCE_FENCE_WAIT=1`, look
at the X server's idle/release timing and its `DMA_BUF_IOCTL_SYNC` use, not at Mesa.

---

## 1. Configuration being analysed

* Termux `mesa` 26.2.6 = upstream `mesa-26.2.6.tar.xz` + `termux-packages/packages/mesa/*.patch`
  at commit `84f9775ddbeda5eb04ceabd7c86f340ac4c9ccbb` ("bump(main/mesa): 26.2.6").
  `build.sh` adds `-Dvulkan-drivers=swrast,virtio,freedreno -Dfreedreno-kmds=msm,kgsl -Dplatforms=x11,wayland`.
* None of Termux's patches touches the WSI fence path. Relevant ones:
  * `0000-disable-android-detection.patch`: `DETECT_OS_ANDROID` is 0, so all the
    Linux code paths are compiled (libdrm, `HAVE_LIBDRM`, X11 DRI3 WSI). No Android WSI.
  * `0006-wsi-no-pthread_cancel.patch`: `wsi_common_display.c` only (KMS display WSI, not used here).
  * `0014-replace-turnip-wait_timestamp_safe-assert.patch`: kgsl CPU wait, turns an assert into a warning.
* Line numbers below are for **pristine mesa 26.2.6** (CI job `patch-check` prints them,
  `scripts/code-locations.sh`). Termux's patches do not shift these files except
  `tu_knl_kgsl.cc`, where `0014` adds one line at ~805: in the Termux-patched source the kgsl
  references from `:1009` on are +1.

## 2. Code path: vkQueuePresentKHR → PresentPixmap (kgsl, X11 DRI3)

### Device / WSI setup
1. `tu_wsi.cc:42` `wsi_device_init(..., master_fd /* -1 on kgsl */, ..., sw_device=false)`.
   `tu_wsi.cc:26` `tu_wsi_can_present_on_device()` = `wsi_common_drm_devices_equal(fd, local_fd)`;
   on kgsl `local_fd` is `/dev/kgsl-3d0`, so `drmGetDevice2()` fails and this returns **false** for any fd.
2. `wsi_common.c:139-169`: WSI queries `GetPhysicalDeviceExternalSemaphoreProperties` (`:153`).
   Turnip-kgsl's binary sync type `vk_kgsl_sync_type` (`tu_knl_kgsl.cc:1252`) has
   `export_sync_file`, so `vk_sync_semaphore_export_types()` (`vk_semaphore.c:63`) reports
   SYNC_FD exportable → `wsi->semaphore_export_handle_types |= SYNC_FD`.
   `wsi_common.c:222` loads `GetMemoryFdKHR` (not sw).

### Swapchain creation (`x11_surface_create_swapchain`)
3. `wsi_common_x11.c:3218` `.same_gpu = wsi_x11_check_dri3_compatible()` (`:158`): if the X server's
   `DRI3Open` returns no fd → `true`; if it returns an fd → `can_present_on_device()` → **false** on kgsl.
   `explicit_sync` needs DRI3 1.4 + `PRESENT_CAPABILITY_SYNCOBJ` + DRM syncobj support → false on kgsl.
   With DRI3 ≥1.2 the server's modifier list (LINEAR only) is used.
4. `wsi_common.c` `wsi_swapchain_init`: blit type from `wsi_drm_image_needs_buffer_blit()`
   (`wsi_common_drm.c:910`): `same_gpu=false` → **BUFFER_BLIT ("prime")**, otherwise native
   with LINEAR modifier.
   * native: `wsi_create_native_image_mem()` (`wsi_common_drm.c:760`): exportable (DMA_BUF)
     dedicated allocation of the render image.
   * prime: `wsi_create_prime_image_mem()` (`:859`): render image + exportable linear buffer, a GPU
     copy at present time.
   * Both: `tu_knl_kgsl.cc:259` `TU_BO_ALLOC_SHAREABLE` → `bo_init_new_dmaheap()` (`:81`):
     `DMA_HEAP_IOCTL_ALLOC` on `/dev/dma_heap/system`, imported into kgsl. `GetMemoryFdKHR` →
     `kgsl_bo_export_dmabuf()` (`:406`) = dup of that dma-buf. `wsi_init_image_dmabuf_fd()`
     (`wsi_common_drm.c:743`) stores it as `image->dma_buf_fd`. This is the fd the X server
     receives (`wsi_common_x11.c:2682` `xcb_dri3_pixmap_from_buffers`), i.e. the
     "LINEAR dma-buf from /dev/dma_heap/system" seen on the phone. **So the fd Mesa would attach
     the fence to is the one the server inspects.**
5. `wsi_common.c:576` → `wsi_drm_init_swapchain_implicit_sync()` (`wsi_common_drm.c:368`):
   runs the self-test `wsi_drm_check_dma_buf_sync_file_import_export()` (`:95`):
   allocate 4096 bytes exportable (→ dma-heap on kgsl), `GetMemoryFdKHR`,
   `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` (`:48`), `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` (`:70`).
   PASS → creates `chain->dma_buf_semaphore` (binary, exportable SYNC_FD).
   FAIL → silently no semaphore (the `mesa_logd` messages are compiled out in release builds,
   which is why nothing was seen on the phone), and `implicit_sync=true` is passed to the driver —
   which Turnip ignores; kgsl has no implicit sync at all.

### Each present
6. `wsi_common_queue_present()` (`wsi_common.c:2440`): `:2641` adds `dma_buf_semaphore` to the
   signal list of the WSI's own submit, which waits on the app's semaphores (and does the prime blit
   if any).
7. kgsl submit (`tu_knl_kgsl.cc`): with no command buffers (native path) `:1402` merges the waits
   plus the queue's last timestamp (`kgsl_syncobj_merge()`, `:1069`) and **copies** the result into
   the signal semaphores; with commands (prime blit) `:1670` sets them to the new submit timestamp.
   Either way the semaphore is in state `TS` (a kgsl context timestamp).
8. `wsi_common.c:2881` → `wsi_signal_dma_buf_from_semaphore()` (`wsi_common_drm.c:191`):
   `GetSemaphoreFdKHR(SYNC_FD)` (`vk_semaphore.c:629`, `:684`) → `vk_kgsl_sync_export_sync_file()`
   (`tu_knl_kgsl.cc:1244`) → `kgsl_syncobj_export()` (`:1009`) → `timestamp_to_fd()` (`:717`,
   `IOCTL_KGSL_TIMESTAMP_EVENT` / `KGSL_TIMESTAMP_EVENT_FENCE`) → sync_file;
   then **`DMA_BUF_IOCTL_IMPORT_SYNC_FILE(image->dma_buf_fd, RW)`** — *this is where the render
   fence is attached*. Note: `timestamp_to_fd()` returns -1 silently on ioctl failure, and
   `kgsl_syncobj_export()` returns -1 for SIGNALED/UNSIGNALED state; the import of -1 then fails
   with EINVAL and the present is dropped (it would not go silent).
9. `wsi_common.c:2898` → `x11_queue_present()` (`wsi_common_x11.c:2215`) pushes to the present
   thread `x11_manage_present_queue()` (`:2499`). **`:2529`: in MAILBOX mode (and IMMEDIATE on
   Xwayland) the thread first does a CPU `WaitForFences` on the frame's fence**
   (`x11_needs_wait_for_fences()`, `:1987`), i.e. the GPU has finished before PresentPixmap is sent.
10. `x11_present_to_x11_dri3()` (`:1751`) → `xcb_present_pixmap()` (`:1826`) with
    `idle_fence = image->sync_fence` (xshmfence) and no wait fence.
    The image is reused after the server triggers that xshmfence / sends IdleNotify.

## 3. What reading the code shows

For this configuration every step needed to attach the fence exists and nothing kgsl-specific
skips it: the self-test uses an allocation kgsl serves from the same dma-heap, the semaphore type
is SYNC_FD-exportable, and the fd imported into is the fd sent to the server. I did not find a
code path that would make Mesa silently present without importing a fence while the self-test
passes.

Important for interpreting the server's measurement: the kernel's `DMA_BUF_IOCTL_EXPORT_SYNC_FILE`
uses `dma_resv_get_singleton()`, which **skips fences that are already signalled** and returns the
stub fence if none are left. So "only the stub fence on 100% of frames" means *either* no fence was
attached *or* every attached fence had signalled by the time the server looked. These two are
indistinguishable from the server side. In MAILBOX mode (step 9) the second is guaranteed by
design — and the phone still tore in MAILBOX mode.

## 4. Ranked hypotheses

**H1 — fences are attached (or the frame is already complete), and the tearing comes from the
server side: buffer reuse or CPU cache.** *Most likely.*
* For: code path complete (section 3); MAILBOX makes Mesa CPU-wait for the GPU before
  PresentPixmap, yet tearing persisted (unless Mesa misdetects the server as Xwayland — logged as
  `xwayland=`); 100% stub is expected when the server checks at/after vblank or after the wait.
* Two sub-mechanisms, both server side:
  * (a) the server triggers the idle xshmfence / sends PresentIdleNotify before its CPU copy of
    that pixmap has finished (or copies lazily later), so the client renders the next frame into a
    buffer that is still being read;
  * (b) the CPU read of the `/dev/dma_heap/system` buffer (cached pages) is not bracketed by
    `DMA_BUF_IOCTL_SYNC` (`DMA_BUF_SYNC_START|READ` … `END`), so stale cache lines from an earlier
    read of the same buffer appear as horizontal bands.
* `TU_DEBUG=syncdraw` reducing (not removing) tearing fits (a): it slows the client so overlap with
  the server's copy is less frequent.
* Test: `TMD_FORCE_FENCE_WAIT=1` (debug build). If tearing remains with frames guaranteed complete
  before PresentPixmap, render fences are not the cause.

**H2 — the self-test fails on this kernel/heap, so no `dma_buf_semaphore` exists.**
* For: matches "no fence ever"; the failure is completely silent in release builds.
* Against: the server's own `EXPORT_SYNC_FILE` on these buffers works, and `IMPORT_SYNC_FILE` is in
  core dma-buf since Linux 6.0 (Android 16 on SM8750 runs a 6.6 GKI). A vendor hook could still
  reject it.
* Test: `wsi selftest ... FAIL step=... errno=...` line.

**H3 — kgsl turns the timestamp into a sync_file that is already signalled / wrong.**
`timestamp_to_fd()` failures map to fd -1 silently; the merge bug (H4) can drop fences.
* Test: `semaphore->SYNC_FD ... PENDING/ signaled` and `kgsl ... TIMESTAMP_EVENT failed` lines.

**H4 — `kgsl_syncobj_merge()` drops fences** (real bug, see section 5). Only hit when one
submit waits on semaphores from two kgsl queues, or a timestamp semaphore followed by an imported
sync_fd semaphore. For the present submit this would make the dma-buf fence cover too little
(or fail the present), so it is a candidate only if Chromium waits on mixed semaphores.

**H5 — prime path.** If `same_gpu=0` (server's `DRI3Open` returns an fd), a GPU blit into a
separate linear buffer is used. The fence is still imported into the presented (linear) buffer,
so this alone does not explain missing fences; logged as `path=`.

## 5. Patches

* `patches/9000-tmd-debug-wsi-fences.patch` — instrumentation, inactive unless `TMD_DEBUG=1`
  (or `TMD_FORCE_FENCE_WAIT=1`). Adds `src/util/tmd_debug.h` and small hooks marked `TMD-DEBUG` in
  `wsi_common_drm.c` (self-test step + errno, swapchain semaphore, per present export/import result
  and the dma-buf's fence state right after the import), `wsi_common.c` (per-present path line,
  rate-limited to first 20 then every 300th), `wsi_common_x11.c` (swapchain parameters, forced fence
  wait), `tu_knl_kgsl.cc` (TIMESTAMP_EVENT failures). See TEST.md for the output format.
* `patches/fix-9100-kgsl-syncobj-merge.patch` — fixes two wrong branches in
  `kgsl_syncobj_merge()` (`tu_knl_kgsl.cc:1069`):
  * TS + TS on different queues: upstream switched `ret` to FD with `ret.fd == -1` and merged only
    the other fence; `sync_merge(-1, x)` fails, so `ret` ended as "FD -1" = signalled. Both
    fences lost.
  * TS + FD: upstream called `kgsl_syncobj_ts_to_fd(sync)` on the FD-state object (which asserts
    `state == TS` in debug builds and reads a stale queue/timestamp in release), and never merged
    `sync->fd`.
  * Fix: convert `ret`'s own timestamp to a sync_file first, then merge; a negative fd means
    "already signalled"; an all-signalled result becomes `SIGNALED` instead of "FD -1" (which the
    submit path would pass to kgsl as fence fd -1).
  * Why it is safe: it only changes branches that were unreachable-by-assert in debug builds and
    wrong in release; the correct branches and all non-kgsl drivers are untouched; it uses only
    existing kgsl calls (`IOCTL_KGSL_TIMESTAMP_EVENT`, `SYNC_IOC_MERGE`). On devices where these
    branches are never hit it changes nothing.
  * Honest scope: this is a correctness fix I found while tracing, **not** a proven fix for the
    observed tearing. The `fix` artifact also contains the debug logging so its effect can be
    measured with the same steps.

No fix for the "stub fence" observation itself is proposed, because the code reading does not show
Mesa skipping the import; a patch would be guesswork until the TMD log says which step (if any)
fails. If the log shows H2, the next step is to log/handle the specific ioctl failure; if H1, the
fix belongs in the X server (signal idle only after the CPU copy; wrap CPU reads in
`DMA_BUF_IOCTL_SYNC`).

## 6. Build

`.github/workflows/build.yml`:
* `patch-check` (~15 s): downloads mesa-26.2.6, verifies the sha256 from Termux's `build.sh`,
  prints the code locations above, applies Termux's patches and ours in build order.
* `build (debug)` / `build (fix)`: termux-packages at the pinned commit, our patches copied into
  `packages/mesa/`, `./scripts/run-docker.sh ./build-package.sh -I -a aarch64 mesa` (full Termux
  mesa package, dependencies downloaded from the Termux apt repo), then
  `scripts/collect-artifacts.sh` packs `libvulkan_freedreno.so` + an ICD json whose
  `library_path` is `$PREFIX/opt/tmd/<variant>/libvulkan_freedreno.so`.
* Local check done in this session: the patched sources (26.2.4 + Termux patches + ours, the closest
  release reachable from the sandbox) compile warning-free in an x86-64 host build of
  `-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Dplatforms=x11`.
