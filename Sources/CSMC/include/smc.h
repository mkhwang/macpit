#ifndef MACMON_SMC_H
#define MACMON_SMC_H

#include <stdint.h>
#include <stdbool.h>

// AppleSMC user client 래퍼. 80바이트 SMCParamStruct 레이아웃.
typedef struct {
    uint32_t key;      // FourCC (big-endian 정수)
    uint32_t size;     // 데이터 바이트 수
    uint32_t type;     // FourCC 타입 (flt , ui8 , ui16, fpe2 ...)
    uint8_t  attr;
    uint8_t  bytes[32];
} smc_val_t;

int  smc_open(void);                 // 0 = 성공, 그 외 kern_return_t
void smc_close(void);
int  smc_read(uint32_t key, smc_val_t *out);
int  smc_write(uint32_t key, const uint8_t *bytes, uint32_t size);
int  smc_key_info(uint32_t key, smc_val_t *out); // size/type/attr 만 채움
int  smc_key_at_index(uint32_t index, uint32_t *key_out);

#endif
