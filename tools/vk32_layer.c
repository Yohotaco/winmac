// Camada Vulkan do WinMac: no Wine em modo 32 bits (WoW64), o winevulkan cria buffers e imagens com
// VkExternalMemory*CreateInfo do tipo HOST_ALLOCATION (para importar memória abaixo de 4 GB depois).
// O MoltenVK aceita importar essa memória no vkAllocateMemory, mas recusa o tipo no vkCreateBuffer /
// vkCreateImage (VK_ERROR_FEATURE_NOT_PRESENT). Esta camada tira só essa estrutura da cadeia pNext
// durante a chamada; a memória continua sendo importada normalmente.
// Recompilar (headers de github.com/KhronosGroup/Vulkan-Headers, tag v1.4.350):
//   clang -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -O2 -dynamiclib -fvisibility=hidden \
//     -I<Vulkan-Headers>/include -o tools/winmac-vk32.dylib tools/vk32_layer.c && codesign -s - -f tools/winmac-vk32.dylib
#include <string.h>
#include <pthread.h>
#include <vulkan/vulkan.h>
#include <vulkan/vk_layer.h>

#define EXPORT __attribute__((visibility("default")))
#define HOST_TYPES (VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT | \
                    VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_MAPPED_FOREIGN_MEMORY_BIT_EXT)
#define MAX 64

typedef struct { void *key; PFN_vkGetInstanceProcAddr gipa; } inst_entry;
typedef struct {
  void *key; PFN_vkGetDeviceProcAddr gdpa;
  PFN_vkCreateBuffer create_buffer; PFN_vkCreateImage create_image;
} dev_entry;

static inst_entry insts[MAX];
static dev_entry devs[MAX];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void *key_of(const void *h) { return *(void *const *)h; }   // tabela de despacho do loader
static inst_entry *find_inst(void *k) { for (int i = 0; i < MAX; i++) if (insts[i].key == k) return &insts[i]; return NULL; }
static dev_entry *find_dev(void *k) { for (int i = 0; i < MAX; i++) if (devs[i].key == k) return &devs[i]; return NULL; }

typedef struct node { VkStructureType sType; struct node *pNext; } node;

// Acha a estrutura de memória externa só com tipos do host; devolve o "elo" que aponta para ela
static node **find_host_ext(const void *info, VkStructureType type) {
  node **link = &((node *)info)->pNext;
  for (; *link; link = &(*link)->pNext) {
    if ((*link)->sType != type) continue;
    VkExternalMemoryHandleTypeFlags t = (type == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO)
      ? ((VkExternalMemoryBufferCreateInfo *)*link)->handleTypes
      : ((VkExternalMemoryImageCreateInfo *)*link)->handleTypes;
    if (t && !(t & ~HOST_TYPES)) return link;
  }
  return NULL;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateBuffer(VkDevice dev, const VkBufferCreateInfo *info,
    const VkAllocationCallbacks *alloc, VkBuffer *out) {
  dev_entry *d = find_dev(key_of(dev));
  node **link = find_host_ext(info, VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO), *skipped = NULL;
  if (link) { skipped = *link; *link = skipped->pNext; }
  VkResult r = d->create_buffer(dev, info, alloc, out);
  if (link) *link = skipped;
  return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateImage(VkDevice dev, const VkImageCreateInfo *info,
    const VkAllocationCallbacks *alloc, VkImage *out) {
  dev_entry *d = find_dev(key_of(dev));
  node **link = find_host_ext(info, VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO), *skipped = NULL;
  if (link) { skipped = *link; *link = skipped->pNext; }
  VkResult r = d->create_image(dev, info, alloc, out);
  if (link) *link = skipped;
  return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo *info,
    const VkAllocationCallbacks *alloc, VkInstance *out) {
  VkLayerInstanceCreateInfo *chain = (VkLayerInstanceCreateInfo *)info->pNext;
  while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
    chain = (VkLayerInstanceCreateInfo *)chain->pNext;
  if (!chain) return VK_ERROR_INITIALIZATION_FAILED;
  PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
  PFN_vkCreateInstance next = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
  VkResult r = next(info, alloc, out);
  if (r != VK_SUCCESS) return r;
  pthread_mutex_lock(&lock);
  inst_entry *e = find_inst(key_of(*out)); if (!e) e = find_inst(NULL);
  if (e) { e->key = key_of(*out); e->gipa = gipa; }
  pthread_mutex_unlock(&lock);
  return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice phys, const VkDeviceCreateInfo *info,
    const VkAllocationCallbacks *alloc, VkDevice *out) {
  VkLayerDeviceCreateInfo *chain = (VkLayerDeviceCreateInfo *)info->pNext;
  while (chain && !(chain->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && chain->function == VK_LAYER_LINK_INFO))
    chain = (VkLayerDeviceCreateInfo *)chain->pNext;
  if (!chain) return VK_ERROR_INITIALIZATION_FAILED;
  PFN_vkGetInstanceProcAddr gipa = chain->u.pLayerInfo->pfnNextGetInstanceProcAddr;
  PFN_vkGetDeviceProcAddr gdpa = chain->u.pLayerInfo->pfnNextGetDeviceProcAddr;
  chain->u.pLayerInfo = chain->u.pLayerInfo->pNext;
  PFN_vkCreateDevice next = (PFN_vkCreateDevice)gipa(VK_NULL_HANDLE, "vkCreateDevice");
  VkResult r = next(phys, info, alloc, out);
  if (r != VK_SUCCESS) return r;
  pthread_mutex_lock(&lock);
  dev_entry *e = find_dev(key_of(*out)); if (!e) e = find_dev(NULL);
  if (e) {
    e->key = key_of(*out); e->gdpa = gdpa;
    e->create_buffer = (PFN_vkCreateBuffer)gdpa(*out, "vkCreateBuffer");
    e->create_image = (PFN_vkCreateImage)gdpa(*out, "vkCreateImage");
  }
  pthread_mutex_unlock(&lock);
  return r;
}

static VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice dev, const VkAllocationCallbacks *alloc) {
  dev_entry *d = find_dev(key_of(dev));
  PFN_vkDestroyDevice next = (PFN_vkDestroyDevice)d->gdpa(dev, "vkDestroyDevice");
  pthread_mutex_lock(&lock); d->key = NULL; pthread_mutex_unlock(&lock);
  next(dev, alloc);
}

static VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance inst, const VkAllocationCallbacks *alloc) {
  inst_entry *e = find_inst(key_of(inst));
  PFN_vkDestroyInstance next = (PFN_vkDestroyInstance)e->gipa(inst, "vkDestroyInstance");
  pthread_mutex_lock(&lock); e->key = NULL; pthread_mutex_unlock(&lock);
  next(inst, alloc);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL winmac_vk32_GetDeviceProcAddr(VkDevice dev, const char *name) {
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)winmac_vk32_GetDeviceProcAddr;
  if (!strcmp(name, "vkCreateBuffer")) return (PFN_vkVoidFunction)CreateBuffer;
  if (!strcmp(name, "vkCreateImage")) return (PFN_vkVoidFunction)CreateImage;
  if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)DestroyDevice;
  dev_entry *d = find_dev(key_of(dev));
  return d ? d->gdpa(dev, name) : NULL;
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL winmac_vk32_GetInstanceProcAddr(VkInstance inst, const char *name) {
  if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)winmac_vk32_GetInstanceProcAddr;
  if (!strcmp(name, "vkCreateInstance")) return (PFN_vkVoidFunction)CreateInstance;
  if (!strcmp(name, "vkDestroyInstance")) return (PFN_vkVoidFunction)DestroyInstance;
  if (!strcmp(name, "vkCreateDevice")) return (PFN_vkVoidFunction)CreateDevice;
  if (!strcmp(name, "vkGetDeviceProcAddr")) return (PFN_vkVoidFunction)winmac_vk32_GetDeviceProcAddr;
  if (!strcmp(name, "vkCreateBuffer")) return (PFN_vkVoidFunction)CreateBuffer;
  if (!strcmp(name, "vkCreateImage")) return (PFN_vkVoidFunction)CreateImage;
  if (!strcmp(name, "vkDestroyDevice")) return (PFN_vkVoidFunction)DestroyDevice;
  if (!inst) return NULL;
  inst_entry *e = find_inst(key_of(inst));
  return e ? e->gipa(inst, name) : NULL;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
  if (v->loaderLayerInterfaceVersion > 2) v->loaderLayerInterfaceVersion = 2;
  v->pfnGetInstanceProcAddr = winmac_vk32_GetInstanceProcAddr;
  v->pfnGetDeviceProcAddr = winmac_vk32_GetDeviceProcAddr;
  v->pfnGetPhysicalDeviceProcAddr = NULL;
  return VK_SUCCESS;
}
