# termux-mesa-debug

Debug builds of Termux's Mesa (Turnip, freedreno Vulkan on kgsl) to find out why X11 WSI presents carry no render fence on their dma-bufs.

## Observation (Snapdragon 8 Elite / Adreno 830, Android 16, Termux mesa 26.2.6)
- Chromium (ANGLE Vulkan on Turnip) and other Vulkan X11 clients send LINEAR dma-bufs from `/dev/dma_heap/system` through DRI3/Present to a Termux:X11-based X server, which copies them with the CPU.
- Before each CPU read the server calls `DMA_BUF_IOCTL_EXPORT_SYNC_FILE` and `SYNC_IOC_FILE_INFO`: 100% of frames have only the kernel stub fence (no client fence, none pending, none signalled).
- Mesa's common WSI (`wsi_common_drm.c`, `wsi_common.c`) should import the render semaphore's sync_file into the dma-buf with `DMA_BUF_IOCTL_IMPORT_SYNC_FILE` at each present, gated on the self-test `wsi_drm_check_dma_buf_sync_file_import_export`. Turnip's kgsl backend can export sync files (`tu_knl_kgsl.cc`).
- Result: consumers read frames that are still being rendered (horizontal tearing on Android Auto projection, where the GPU is busier).

## Goal
Find which step fails on this device and fix it, so Mesa attaches the fence (or produce the narrowest correct patch).
