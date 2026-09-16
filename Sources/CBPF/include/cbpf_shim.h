// BPF access for Swift.
//
// Two things here do not import into Swift and so have to live in C:
//   * ioctl(2) is C-variadic, which Swift cannot call.
//   * BIOCSETIF, BIOCSBLEN and the rest are _IOW()/_IOR() function-like
//     macros, so they are not visible as constants either.
// Struct layout knowledge (bpf_hdr, BPF_WORDALIGN) is kept here too, so the
// Swift side never has to guess at padding.

#ifndef CBPF_SHIM_H
#define CBPF_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Outcome of walking /dev/bpf0, /dev/bpf1, ... looking for a free device.
typedef struct {
    int fd;                 ///< >= 0 on success, -1 otherwise.
    int last_errno;         ///< errno from the final failed attempt.
    int attempts;           ///< how many device nodes were tried.
    /// 1 when every attempt failed with EACCES/EPERM. That is the
    /// "ChmodBPF is not installed" case and wants its own error message,
    /// not the generic one.
    int permission_denied;
    char device[32];        ///< e.g. "/dev/bpf4" on success.
} mcv_bpf_open_result;

/// Walks /dev/bpfN from 0 upward. EBUSY means the device is in use by another
/// process, so move to the next one; anything else stops the walk.
mcv_bpf_open_result mcv_bpf_open(int max_devices);

void mcv_bpf_close(int fd);

/// Buffer length, in bytes. MUST be set before mcv_bpf_set_interface --
/// the kernel refuses BIOCSBLEN once an interface is bound.
int mcv_bpf_set_buffer_length(int fd, unsigned int length);

/// Reads back the length the kernel actually settled on. Every read(2) on the
/// fd must use exactly this size or it fails with EINVAL.
int mcv_bpf_get_buffer_length(int fd, unsigned int *out_length);

/// Binds to an interface, e.g. "en7". Call after mcv_bpf_set_buffer_length.
int mcv_bpf_set_interface(int fd, const char *ifname);

/// Deliver each packet as it arrives instead of waiting for the buffer to
/// fill. Not optional: without it a quiet VLAN delivers nothing for minutes
/// and then a burst, and every rate computed from that is wrong.
int mcv_bpf_set_immediate(int fd, int on);

/// Promiscuous mode. Without it a mirror port shows you almost nothing,
/// because none of the mirrored frames are addressed to this host.
int mcv_bpf_set_promiscuous(int fd);

/// Don't capture packets this host itself transmitted.
int mcv_bpf_set_see_sent(int fd, int on);

/// Read timeout, so the blocking read(2) wakes up periodically and the
/// capture thread can notice a stop request.
int mcv_bpf_set_read_timeout(int fd, unsigned int milliseconds);

/// Data link type; DLT_EN10MB (1) is the Ethernet case this app parses.
int mcv_bpf_get_datalink(int fd, unsigned int *out_dlt);

/// One BPF instruction. Layout-identical to `struct bpf_insn`.
typedef struct {
    uint16_t code;
    uint8_t  jt;
    uint8_t  jf;
    uint32_t k;
} mcv_bpf_insn;

/// Installs a kernel filter. Filtering here rather than in Swift is the whole
/// game on a mirrored uplink: most frames are unicast, and copying them to
/// userspace only to drop them is the bulk of the cost.
int mcv_bpf_set_filter(int fd, const mcv_bpf_insn *insns, unsigned int count);

/// BIOCGSTATS. bs_drop rising means the capture is behind and every rate
/// shown is understated -- the UI says so rather than quietly lying.
int mcv_bpf_get_stats(int fd, unsigned int *out_received, unsigned int *out_dropped);

/// Walks the packets inside one read(2) buffer. A single read returns many
/// packets, each behind a struct bpf_hdr and each padded out to
/// BPF_WORDALIGN(bh_hdrlen + bh_caplen).
///
/// Returns 1 and fills the out params when a packet was decoded, 0 when the
/// buffer is exhausted or the remaining bytes are too short/inconsistent to
/// be a header (a truncated tail is normal and must not be fatal).
int mcv_bpf_next_packet(const void *buffer,
                        size_t buffer_length,
                        size_t offset,
                        size_t *out_payload_offset,
                        uint32_t *out_captured_length,
                        uint32_t *out_original_length,
                        int64_t *out_timestamp_seconds,
                        int32_t *out_timestamp_microseconds,
                        size_t *out_next_offset);

#ifdef __cplusplus
}
#endif
#endif
