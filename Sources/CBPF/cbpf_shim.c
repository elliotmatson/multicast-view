#include "cbpf_shim.h"

#include <errno.h>
#include <stddef.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <net/bpf.h>
#include <net/if.h>

mcv_bpf_open_result mcv_bpf_open(int max_devices) {
    mcv_bpf_open_result result;
    memset(&result, 0, sizeof(result));
    result.fd = -1;
    result.permission_denied = 1;   // cleared by any failure that isn't EACCES/EPERM

    if (max_devices <= 0) max_devices = 256;

    for (int index = 0; index < max_devices; index++) {
        char path[32];
        snprintf(path, sizeof(path), "/dev/bpf%d", index);

        int fd = open(path, O_RDONLY);
        result.attempts = index + 1;

        if (fd >= 0) {
            result.fd = fd;
            result.last_errno = 0;
            result.permission_denied = 0;
            snprintf(result.device, sizeof(result.device), "%s", path);
            return result;
        }

        result.last_errno = errno;

        if (errno == EBUSY) {
            // In use by another capture process. Perfectly normal; try the next.
            result.permission_denied = 0;
            continue;
        }
        if (errno == EACCES || errno == EPERM) {
            // Keep walking: the ChmodBPF group membership applies to all of
            // them, so if one is denied the rest will be too, but a later
            // device could still be readable on an oddly configured machine.
            continue;
        }
        if (errno == ENOENT || errno == ENXIO) {
            // Ran off the end of the device nodes that exist.
            result.permission_denied = 0;
            break;
        }
        result.permission_denied = 0;
        break;
    }

    if (result.fd < 0 && result.attempts == 0) result.permission_denied = 0;
    return result;
}

void mcv_bpf_close(int fd) {
    if (fd >= 0) close(fd);
}

int mcv_bpf_set_buffer_length(int fd, unsigned int length) {
    u_int value = (u_int)length;
    return ioctl(fd, BIOCSBLEN, &value);
}

int mcv_bpf_get_buffer_length(int fd, unsigned int *out_length) {
    u_int value = 0;
    int rc = ioctl(fd, BIOCGBLEN, &value);
    if (rc == 0 && out_length) *out_length = (unsigned int)value;
    return rc;
}

int mcv_bpf_set_interface(int fd, const char *ifname) {
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, ifname, sizeof(request.ifr_name) - 1);
    return ioctl(fd, BIOCSETIF, &request);
}

int mcv_bpf_set_immediate(int fd, int on) {
    u_int value = on ? 1 : 0;
    return ioctl(fd, BIOCIMMEDIATE, &value);
}

int mcv_bpf_set_promiscuous(int fd) {
    return ioctl(fd, BIOCPROMISC, NULL);
}

int mcv_bpf_set_see_sent(int fd, int on) {
    u_int value = on ? 1 : 0;
    return ioctl(fd, BIOCSSEESENT, &value);
}

int mcv_bpf_set_read_timeout(int fd, unsigned int milliseconds) {
    struct timeval timeout;
    timeout.tv_sec = (time_t)(milliseconds / 1000u);
    timeout.tv_usec = (suseconds_t)((milliseconds % 1000u) * 1000u);
    return ioctl(fd, BIOCSRTIMEOUT, &timeout);
}

int mcv_bpf_get_datalink(int fd, unsigned int *out_dlt) {
    u_int value = 0;
    int rc = ioctl(fd, BIOCGDLT, &value);
    if (rc == 0 && out_dlt) *out_dlt = (unsigned int)value;
    return rc;
}

int mcv_bpf_set_filter(int fd, const mcv_bpf_insn *insns, unsigned int count) {
    struct bpf_program program;
    memset(&program, 0, sizeof(program));
    program.bf_len = count;
    // mcv_bpf_insn is laid out exactly as struct bpf_insn.
    program.bf_insns = (struct bpf_insn *)(void *)(uintptr_t)insns;
    return ioctl(fd, BIOCSETF, &program);
}

int mcv_bpf_get_stats(int fd, unsigned int *out_received, unsigned int *out_dropped) {
    struct bpf_stat stats;
    memset(&stats, 0, sizeof(stats));
    int rc = ioctl(fd, BIOCGSTATS, &stats);
    if (rc == 0) {
        if (out_received) *out_received = (unsigned int)stats.bs_recv;
        if (out_dropped) *out_dropped = (unsigned int)stats.bs_drop;
    }
    return rc;
}

/// The real extent of the header's fields, which is NOT sizeof(struct bpf_hdr).
///
/// On 64-bit Darwin the fields occupy 18 bytes (an 8-byte timeval32, two
/// 32-bit lengths, a 16-bit header length) but the struct is padded out to 20.
/// The kernel reports the unpadded 18 in bh_hdrlen, so comparing against
/// sizeof() rejects every packet -- silently, because a capture that decodes
/// nothing looks exactly like a quiet network. libpcap carries the same
/// workaround as SIZEOF_BPF_HDR.
#define MCV_BPF_MIN_HDRLEN (offsetof(struct bpf_hdr, bh_hdrlen) + sizeof(u_short))

int mcv_bpf_next_packet(const void *buffer,
                        size_t buffer_length,
                        size_t offset,
                        size_t *out_payload_offset,
                        uint32_t *out_captured_length,
                        uint32_t *out_original_length,
                        int64_t *out_timestamp_seconds,
                        int32_t *out_timestamp_microseconds,
                        size_t *out_next_offset) {
    if (buffer == NULL) return 0;
    if (offset >= buffer_length) return 0;
    if (buffer_length - offset < MCV_BPF_MIN_HDRLEN) return 0;

    const struct bpf_hdr *header =
        (const struct bpf_hdr *)(const void *)((const char *)buffer + offset);

    size_t header_length = (size_t)header->bh_hdrlen;
    size_t captured = (size_t)header->bh_caplen;

    // A header that claims a length shorter than the struct, or a packet that
    // runs past the end of what was read, means the buffer is not what we
    // think it is. Stop walking rather than reading past the end.
    if (header_length < MCV_BPF_MIN_HDRLEN) return 0;
    if (header_length > buffer_length - offset) return 0;
    if (captured > buffer_length - offset - header_length) return 0;

    if (out_payload_offset) *out_payload_offset = offset + header_length;
    if (out_captured_length) *out_captured_length = (uint32_t)captured;
    if (out_original_length) *out_original_length = (uint32_t)header->bh_datalen;
    if (out_timestamp_seconds) *out_timestamp_seconds = (int64_t)header->bh_tstamp.tv_sec;
    if (out_timestamp_microseconds) *out_timestamp_microseconds = (int32_t)header->bh_tstamp.tv_usec;

    size_t advance = BPF_WORDALIGN(header_length + captured);
    if (advance == 0) return 0;              // cannot make progress; bail out
    if (out_next_offset) *out_next_offset = offset + advance;
    return 1;
}
