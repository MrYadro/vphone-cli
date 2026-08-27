/*
 * vphoned_fwd — Guest-loopback TCP forwarder into the host proxy relay.
 *
 * Listens on 127.0.0.1:<tcpPort> inside the guest and blindly forwards each
 * connection over virtio-vsock to the host relay (vsock port 1338). Used for
 * the system HTTP proxy when the host firewall blocks inbound bridge TCP.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Start the forwarder once (idempotent). Returns YES on success or if
/// already running.
BOOL vp_forward_start(int tcpPort, uint32_t vsockPort);
