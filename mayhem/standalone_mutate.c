#include <stddef.h>

/* The run-once driver has no mutation engine; the harnesses' custom mutators reference this. */
size_t LLVMFuzzerMutate(unsigned char *data, size_t size, size_t max_size) {
    (void)data; (void)max_size;
    return size;
}
