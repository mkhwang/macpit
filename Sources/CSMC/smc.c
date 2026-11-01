#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

static io_connect_t g_conn = 0;

int smc_open(void) {
    if (g_conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = 0; return kr; }
    return 0;
}

void smc_close(void) {
    if (g_conn) { IOServiceClose(g_conn); g_conn = 0; }
}

static int call(SMCParamStruct *in, SMCParamStruct *out) {
    if (!g_conn) { int r = smc_open(); if (r) return r; }
    size_t outSize = sizeof(SMCParamStruct);
    kern_return_t kr = IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &outSize);
    if (kr != KERN_SUCCESS) return kr;
    if (out->result != 0) return 0x1000 + out->result; // SMC 레벨 에러 (0x84 = key not found 등)
    return 0;
}

int smc_key_info(uint32_t key, smc_val_t *v) {
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    int r = call(&in, &out);
    if (r) return r;
    memset(v, 0, sizeof(*v));
    v->key = key;
    v->size = out.keyInfo.dataSize;
    v->type = out.keyInfo.dataType;
    v->attr = out.keyInfo.dataAttributes;
    return 0;
}

// 키 정보(size/type)는 부팅 중 바뀌지 않으므로 캐시 → 읽기 1회당 IOKit 호출 2번 → 1번.
// 호출자(Swift SMC)가 lock 을 잡고 부르므로 별도 동기화 없음.
#define KI_CACHE 256
static struct { uint32_t key, size, type; uint8_t attr; } g_ki[KI_CACHE];

static int key_info_cached(uint32_t key, smc_val_t *v) {
    if (key == 0) return smc_key_info(key, v);
    unsigned h = (key * 2654435761u) % KI_CACHE;
    for (unsigned n = 0; n < KI_CACHE; n++, h = (h + 1) % KI_CACHE) {
        if (g_ki[h].key == key && g_ki[h].size == 0) {   // 무효화된 항목 → 다시 조회
            int r = smc_key_info(key, v);
            if (r == 0 && v->size <= 32) { g_ki[h].size = v->size; g_ki[h].type = v->type; g_ki[h].attr = v->attr; }
            return r;
        }
        if (g_ki[h].key == key) {
            memset(v, 0, sizeof(*v));
            v->key = key; v->size = g_ki[h].size; v->type = g_ki[h].type; v->attr = g_ki[h].attr;
            return 0;
        }
        if (g_ki[h].key == 0) {
            int r = smc_key_info(key, v);
            if (r == 0 && v->size <= 32) { g_ki[h].key = key; g_ki[h].size = v->size; g_ki[h].type = v->type; g_ki[h].attr = v->attr; }
            return r;
        }
    }
    return smc_key_info(key, v);   // 캐시 가득 참
}

static void key_info_forget(uint32_t key) {
    unsigned h = (key * 2654435761u) % KI_CACHE;
    for (unsigned n = 0; n < KI_CACHE && g_ki[h].key; n++, h = (h + 1) % KI_CACHE)
        if (g_ki[h].key == key) { g_ki[h].size = 0; break; }   // 키는 남겨 탐색 체인 유지
}

int smc_read(uint32_t key, smc_val_t *v) {
    int r = key_info_cached(key, v);
    if (r) return r;
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.keyInfo.dataSize = v->size;
    in.data8 = SMC_CMD_READ_BYTES;
    r = call(&in, &out);
    if (r) { key_info_forget(key); return r; }
    memcpy(v->bytes, out.bytes, sizeof(v->bytes));
    return 0;
}

int smc_write(uint32_t key, const uint8_t *bytes, uint32_t size) {
    smc_val_t info;
    int r = smc_key_info(key, &info);
    if (r) return r;
    if (info.size != size) return -2;
    SMCParamStruct in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

int smc_key_at_index(uint32_t index, uint32_t *key_out) {
    SMCParamStruct in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    int r = call(&in, &out);
    if (r) return r;
    *key_out = out.key;
    return 0;
}
