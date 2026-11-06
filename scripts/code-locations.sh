#!/bin/bash
# Prints file:line of the code the NOTES.md walk-through refers to.
# Usage: code-locations.sh <mesa-source-dir>
set -uo pipefail
cd "$1"
w=src/vulkan/wsi k=src/freedreno/vulkan
loc() { # file pattern...
  local f=$1; shift
  for pat in "$@"; do grep -nF -- "$pat" "$f" | sed "s|^|$f:|" | head -n 3; done
}
loc $w/wsi_common.c \
  'wsi_common_queue_present(const struct wsi_device *wsi' \
  'result = wsi_drm_init_swapchain_implicit_sync(chain);' \
  '} else if (swapchain->dma_buf_semaphore != VK_NULL_HANDLE) {' \
  'results[i] = wsi_signal_dma_buf_from_semaphore(swapchain, image);' \
  'results[i] = swapchain->queue_present(swapchain, image_index,' \
  'GetPhysicalDeviceExternalSemaphoreProperties(pdevice, &esi, &esp);' \
  'WSI_GET_CB(GetMemoryFdKHR);'
loc $w/wsi_common_drm.c \
  'wsi_dma_buf_export_sync_file(int dma_buf_fd, int *sync_file_fd)' \
  'wsi_dma_buf_import_sync_file(int dma_buf_fd, int sync_file_fd)' \
  'wsi_drm_check_dma_buf_sync_file_import_export(const struct wsi_device *wsi,' \
  'wsi_signal_dma_buf_from_semaphore(const struct wsi_swapchain *chain,' \
  'wsi_create_sync_for_dma_buf_wait(const struct wsi_swapchain *chain,' \
  'wsi_drm_init_swapchain_implicit_sync(struct wsi_swapchain *chain)' \
  'wsi_common_drm_devices_equal(int fd_a, int fd_b)' \
  'wsi_create_native_image_mem(const struct wsi_swapchain *chain,' \
  'wsi_create_prime_image_mem(const struct wsi_swapchain *chain,' \
  'wsi_init_image_dmabuf_fd(const struct wsi_swapchain *chain,' \
  'wsi_drm_image_needs_buffer_blit(const struct wsi_device *wsi,'
loc $w/wsi_common_x11.c \
  'wsi_x11_check_dri3_compatible(const struct wsi_device *wsi_dev,' \
  'x11_needs_wait_for_fences(const struct wsi_device *wsi_device,' \
  'x11_present_to_x11_dri3(struct x11_swapchain *chain, uint32_t image_index,' \
  'cookie = xcb_present_pixmap(chain->conn,' \
  'x11_queue_present(struct wsi_swapchain *wsi_chain,' \
  'x11_manage_present_queue(void *state)' \
  'x11_needs_wait_for_fences(chain->base.wsi, wsi_conn, present_mode) &&' \
  'xcb_dri3_pixmap_from_buffers_checked(chain->conn,' \
  '.same_gpu = wsi_x11_check_dri3_compatible(wsi_device, conn),'
loc $k/tu_wsi.cc 'tu_wsi_can_present_on_device(VkPhysicalDevice physicalDevice, int fd)' 'result = wsi_device_init(&physical_device->wsi_device,'
loc $k/tu_knl_kgsl.cc \
  'bo_init_new_dmaheap(struct tu_device *dev, struct tu_bo **out_bo, uint64_t size,' \
  'if (flags & TU_BO_ALLOC_SHAREABLE) {' \
  'kgsl_bo_export_dmabuf(struct tu_device *dev, struct tu_bo *bo)' \
  'timestamp_to_fd(struct tu_queue *queue, uint32_t timestamp)' \
  'kgsl_syncobj_export(struct kgsl_syncobj *s, int *pFd)' \
  'kgsl_syncobj_merge(const struct kgsl_syncobj **syncobjs, uint32_t count)' \
  'if (submit->commands.size == 0 && submit->bind_cmds.size == 0) {' \
  'signal_sync->state = KGSL_SYNCOBJ_STATE_TS;' \
  'vk_kgsl_sync_export_sync_file(struct vk_device *device,'
loc src/vulkan/runtime/vk_semaphore.c 'vk_common_GetSemaphoreFdKHR(VkDevice _device,' 'result = vk_sync_export_sync_file(device, sync, pFd);'
exit 0
