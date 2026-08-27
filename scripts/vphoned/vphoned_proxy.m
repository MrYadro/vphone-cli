#import "vphoned_proxy.h"
#import "vphoned_fwd.h"
#import "vphoned_protocol.h"
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

// SCPreferences/SCDynamicStore functions are marked API_UNAVAILABLE(ios) in
// the SDK headers but are exported by the guest's SystemConfiguration
// framework (see SystemConfiguration.tbd). Declared locally to bypass the
// availability guards.

typedef struct __SCDynamicStore *SCDynamicStoreRef;
typedef struct __SCPreferences *SCPreferencesRef;

extern SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef allocator,
                                              CFStringRef name, void *callout,
                                              void *context);
extern CFPropertyListRef SCDynamicStoreCopyValue(SCDynamicStoreRef store,
                                                 CFStringRef key);
extern SCPreferencesRef SCPreferencesCreate(CFAllocatorRef allocator,
                                            CFStringRef name,
                                            CFStringRef prefsID);
extern CFDictionaryRef SCPreferencesPathGetValue(SCPreferencesRef prefs,
                                                 CFStringRef path);
extern Boolean SCPreferencesPathSetValue(SCPreferencesRef prefs,
                                        CFStringRef path,
                                        CFPropertyListRef value);
extern Boolean SCPreferencesCommitChanges(SCPreferencesRef prefs);
extern Boolean SCPreferencesApplyChanges(SCPreferencesRef prefs);

static BOOL write_service_value(SCPreferencesRef prefs, NSString *serviceID,
                                NSString *key, id value);

// MARK: - Helpers

/// Interface summary for diagnostics: "en0:up:no-ip, lo0:up:127.0.0.1".
static NSString *interface_summary(void) {
  struct ifaddrs *ifap = NULL;
  if (getifaddrs(&ifap) != 0)
    return @"ifaddrs-failed";
  NSMutableString *out = [NSMutableString string];
  NSMutableDictionary *seen = [NSMutableDictionary dictionary];
  for (struct ifaddrs *cur = ifap; cur != NULL; cur = cur->ifa_next) {
    NSString *name = [NSString stringWithUTF8String:cur->ifa_name];
    NSMutableString *entry = seen[name];
    if (!entry) {
      entry = [NSMutableString stringWithFormat:@"%@:%s", name,
               (cur->ifa_flags & IFF_UP) ? "up" : "down"];
      seen[name] = entry;
    }
    if (cur->ifa_addr && cur->ifa_addr->sa_family == AF_INET) {
      char buf[INET_ADDRSTRLEN] = {0};
      struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
      if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)))
        [entry appendFormat:@":%s", buf];
    }
  }
  freeifaddrs(ifap);
  for (NSString *key in seen) {
    if (out.length)
      [out appendString:@", "];
    [out appendString:seen[key]];
  }
  return out;
}

/// Active global IPv4 entity: { Router, ServiceID, Addresses, ... } or nil.
static NSDictionary *global_ipv4(void) {
  SCDynamicStoreRef store =
      SCDynamicStoreCreate(NULL, CFSTR("vphoned"), NULL, NULL);
  if (!store)
    return nil;
  CFPropertyListRef value =
      SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
  CFRelease(store);
  if (!value)
    return nil;
  return (NSDictionary *)CFBridgingRelease(value);
}

static NSString *service_proxies_path(NSString *serviceID) {
  return [NSString stringWithFormat:@"/Setup:/Network/Service/%@/Proxies",
                                    serviceID];
}

static NSMutableDictionary *read_proxies(SCPreferencesRef prefs,
                                         NSString *serviceID) {
  CFPropertyListRef v = SCPreferencesPathGetValue(
      prefs, (__bridge CFStringRef)service_proxies_path(serviceID));
  if (!v)
    return [NSMutableDictionary dictionary];
  return [NSMutableDictionary dictionaryWithDictionary:(__bridge id)v];
}

static BOOL write_proxies(SCPreferencesRef prefs, NSString *serviceID,
                          NSDictionary *proxies) {
  return write_service_value(prefs, serviceID, @"Proxies", proxies) &&
         SCPreferencesCommitChanges(prefs) &&
         SCPreferencesApplyChanges(prefs);
}

static NSDictionary *read_path(SCPreferencesRef prefs, CFStringRef path) {
  CFPropertyListRef v = SCPreferencesPathGetValue(prefs, path);
  if (!v || CFGetTypeID(v) != CFDictionaryGetTypeID())
    return nil;
  return [NSDictionary dictionaryWithDictionary:(__bridge id)v];
}

static BOOL write_path(SCPreferencesRef prefs, CFStringRef path,
                       NSDictionary *value) {
  return SCPreferencesPathSetValue(prefs, path,
                                   (__bridge CFPropertyListRef)value);
}

/// Path of the active network set (e.g. "/Sets/<guid>") or nil.
static NSString *current_set_path(SCPreferencesRef prefs) {
  CFPropertyListRef v =
      SCPreferencesPathGetValue(prefs, CFSTR("/Set:/CurrentSet"));
  if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
    return [NSString stringWithFormat:@"%@", (__bridge NSString *)v];
  }
  NSDictionary *sets = read_path(prefs, CFSTR("/Sets"));
  for (NSString *key in sets) {
    NSDictionary *set = [sets[key] isKindOfClass:[NSDictionary class]]
                            ? sets[key]
                            : nil;
    if (set[@"Network"])
      return [NSString stringWithFormat:@"/Sets/%@", key];
  }
  return nil;
}

/// Write a sub-dict of a network service into the ACTIVE set (what configd
/// actually runs) and mirror it into /Setup:.
static BOOL write_service_value(SCPreferencesRef prefs, NSString *serviceID,
                                NSString *key, id value) {
  if (![value isKindOfClass:[NSDictionary class]] &&
      ![value isKindOfClass:[NSString class]] &&
      ![value isKindOfClass:[NSArray class]])
    return NO;
  NSString *setupPath =
      [NSString stringWithFormat:@"/Setup:/Network/Service/%@/%@", serviceID, key];
  BOOL ok = write_path(prefs, (__bridge CFStringRef)setupPath, value);
  NSString *setPath = current_set_path(prefs);
  if (setPath.length) {
    NSString *svcPath =
        [NSString stringWithFormat:@"%@/Network/Service/%@", setPath, serviceID];
    NSDictionary *svc = read_path(
        prefs, (__bridge CFStringRef)svcPath);
    if (!svc) {
      NSDictionary *setupSvc = read_path(
          prefs,
          (__bridge CFStringRef)[NSString
              stringWithFormat:@"/Setup:/Network/Service/%@", serviceID]);
      svc = setupSvc ?: @{};
    }
    NSMutableDictionary *m = [svc mutableCopy];
    m[key] = value;
    ok = write_path(prefs, (__bridge CFStringRef)svcPath, m) && ok;
  }
  return ok;
}

/// Ensure a DHCP IPv4 service exists for `device` (e.g. "en0") in both the
/// active set and /Setup:. Returns the service UUID (nil on failure); writes
/// are left uncommitted for the caller to commit once.
static NSString *ensure_dhcp_service(SCPreferencesRef prefs, NSString *device) {
  NSDictionary *services =
      read_path(prefs, CFSTR("/Setup:/Network/Service")) ?: @{};

  // Register in ServiceOrder (both trees) for a given UUID.
  void (^add_to_order)(NSString *) = ^(NSString *uuid) {
    NSArray *globals = @[
      @"/Setup:/Network/Global/IPv4",
      [NSString stringWithFormat:@"%@/Network/Global/IPv4",
                                 current_set_path(prefs) ?: @""],
    ];
    for (NSString *gp in globals) {
      if (![gp hasPrefix:@"/Setup"] && ![gp hasPrefix:@"/Sets"])
        continue;
      NSMutableDictionary *g =
          [read_path(prefs, (__bridge CFStringRef)gp) mutableCopy];
      if (!g)
        g = [NSMutableDictionary dictionary];
      NSMutableArray *order = [g[@"ServiceOrder"] mutableCopy];
      if (!order)
        order = [NSMutableArray array];
      if (![order containsObject:uuid]) {
        [order addObject:uuid];
        g[@"ServiceOrder"] = order;
        write_path(prefs, (__bridge CFStringRef)gp, g);
      }
    }
  };

  for (NSString *uuid in services) {
    NSDictionary *svc = [services[uuid] isKindOfClass:[NSDictionary class]]
                            ? services[uuid]
                            : nil;
    NSString *dev = svc[@"Interface"][@"DeviceName"];
    if (![dev isEqualToString:device])
      continue;
    NSDictionary *ipv4 = svc[@"IPv4"];
    if (![ipv4 isKindOfClass:[NSDictionary class]] ||
        ![ipv4[@"ConfigMethod"] isEqualToString:@"DHCP"]) {
      write_service_value(prefs, uuid, @"IPv4", @{@"ConfigMethod" : @"DHCP"});
    }
    add_to_order(uuid);
    return uuid;
  }

  NSString *uuid = [[NSUUID UUID] UUIDString];
  if (!write_service_value(prefs, uuid, @"Interface", @{
                             @"DeviceName" : device,
                             @"Hardware" : @"Ethernet",
                             @"Type" : @"Ethernet",
                           }))
    return nil;
  write_service_value(prefs, uuid, @"UserDefinedName", @"Ethernet");
  write_service_value(prefs, uuid, @"IPv4", @{@"ConfigMethod" : @"DHCP"});
  add_to_order(uuid);
  return uuid;
}

/// Configure the service with a static IPv4 (gateway-derived /24, host .100)
/// when the NAT DHCP server is unavailable. Writes left uncommitted.
static BOOL apply_static_ipv4(SCPreferencesRef prefs, NSString *serviceID,
                              NSString *gateway) {
  NSRange lastDot = [gateway rangeOfString:@"." options:NSBackwardsSearch];
  if (lastDot.location == NSNotFound || lastDot.location == 0)
    return NO;
  NSString *base = [gateway substringToIndex:lastDot.location];
  NSString *ip = [NSString stringWithFormat:@"%@.100", base];
  NSDictionary *ipv4 = @{
    @"ConfigMethod" : @"Manual",
    @"Addresses" : @[ ip ],
    @"SubnetMasks" : @[ @"255.255.255.0" ],
    @"Router" : gateway,
  };
  return write_service_value(prefs, serviceID, @"IPv4", ipv4);
}

/// Current primary IPv4 of the first up en* interface (the virtio NIC).
static NSString *first_ipv4_address(void) {
  struct ifaddrs *ifap = NULL;
  if (getifaddrs(&ifap) != 0)
    return nil;
  NSString *found = nil;
  for (struct ifaddrs *cur = ifap; cur != NULL; cur = cur->ifa_next) {
    if (!cur->ifa_addr || cur->ifa_addr->sa_family != AF_INET)
      continue;
    NSString *name = [NSString stringWithUTF8String:cur->ifa_name];
    if (![name hasPrefix:@"en"] || (cur->ifa_flags & IFF_LOOPBACK))
      continue;
    char buf[INET_ADDRSTRLEN] = {0};
    struct sockaddr_in *sin = (struct sockaddr_in *)cur->ifa_addr;
    if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
      NSString *ip = [NSString stringWithUTF8String:buf];
      if (![ip hasPrefix:@"169.254."]) {
        found = ip;
        break;
      }
      if (!found)
        found = ip;
    }
  }
  freeifaddrs(ifap);
  return found;
}

/// First up ethernet-style interface (en*) — the virtio NIC on the VM.
static NSString *first_ethernet_device(void) {
  struct ifaddrs *ifap = NULL;
  if (getifaddrs(&ifap) != 0)
    return nil;
  NSString *found = nil;
  for (struct ifaddrs *cur = ifap; cur != NULL; cur = cur->ifa_next) {
    NSString *name = [NSString stringWithUTF8String:cur->ifa_name];
    if ([name hasPrefix:@"en"] &&
        (cur->ifa_flags & IFF_UP) &&
        !(cur->ifa_flags & IFF_LOOPBACK)) {
      found = name;
      break;
    }
  }
  freeifaddrs(ifap);
  return found;
}

// MARK: - Command Handler

NSDictionary *vp_handle_proxy_command(NSDictionary *msg) {
  NSString *type = msg[@"t"];
  id reqId = msg[@"id"];

  NSDictionary *global = global_ipv4();
  NSString *router = global[@"Router"];
  NSString *serviceID =
      global[@"ServiceID"] ?: global[@"PrimaryService"];

  // -- proxy_set --
  if ([type isEqualToString:@"proxy_set"]) {
    int port = [msg[@"port"] intValue];
    if (port <= 0 || port > 65535) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"missing or invalid port";
      return r;
    }

    NSString *gateway = [msg[@"gateway"] isKindOfClass:[NSString class]]
                            ? msg[@"gateway"]
                            : nil;
    BOOL useVsock = [msg[@"vsock"] boolValue];
    NSString *device = nil;
    NSString *gatewayUsed = nil;
    BOOL staticWritten = NO;

    // Shared bring-up: configd only propagates a service's Proxies into the
    // dynamic store once the service is ACTIVE (has IPv4 and is primary), so
    // both modes need the interface configured, not just the vsock forwarder.
    if (serviceID.length == 0) {
      device = first_ethernet_device();
      if (device) {
        SCPreferencesRef prefs =
            SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
        NSString *uuid = nil;
        if (prefs) {
          uuid = ensure_dhcp_service(prefs, device);
          if (uuid) {
            SCPreferencesCommitChanges(prefs);
            SCPreferencesApplyChanges(prefs);
          }
          CFRelease(prefs);
        }
        for (int i = 0; i < 8 && (router.length == 0 || serviceID.length == 0);
             i++) {
          sleep(1);
          NSDictionary *g = global_ipv4();
          router = g[@"Router"];
          serviceID = g[@"ServiceID"] ?: g[@"PrimaryService"];
        }
        if ((router.length == 0 || serviceID.length == 0) && gateway.length &&
            uuid.length) {
          gatewayUsed = gateway;
          prefs = SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
          if (prefs) {
            if (apply_static_ipv4(prefs, uuid, gateway)) {
              staticWritten = YES;
              SCPreferencesCommitChanges(prefs);
              SCPreferencesApplyChanges(prefs);
            }
            CFRelease(prefs);
          }
          for (int i = 0; i < 8 && (router.length == 0 || serviceID.length == 0);
               i++) {
            sleep(1);
            NSDictionary *g = global_ipv4();
            router = g[@"Router"];
            serviceID = g[@"ServiceID"] ?: g[@"PrimaryService"];
          }
        }
      }
    }

    if (useVsock) {
      // Guest apps proxy to a vphoned loopback forwarder that tunnels to the
      // host relay over virtio-vsock (bridge TCP may be firewalled).
      const int fwdPort = 8899;
      if (!vp_forward_start(fwdPort, 1338)) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"failed to start vsock forwarder";
        return r;
      }

      NSString *svc = serviceID;
      if (svc.length == 0) {
        // Service exists but is not primary yet — write to it anyway; configd
        // activates it once the static config takes effect.
        SCPreferencesRef prefs =
            SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
        if (prefs) {
          NSString *dev2 = device ?: first_ethernet_device();
          svc = dev2 ? ensure_dhcp_service(prefs, dev2) : nil;
          if (svc) {
            SCPreferencesCommitChanges(prefs);
            SCPreferencesApplyChanges(prefs);
          }
          CFRelease(prefs);
        }
      }
      if (svc.length == 0) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = [NSString stringWithFormat:
                         @"no network service for vsock proxy (device=%@ gateway=%@ static=%d); interfaces: %@",
                         device ?: @"(none)", gatewayUsed, staticWritten,
                         interface_summary()];
        return r;
      }

      NSArray *incoming = msg[@"exceptions"];
      NSMutableArray *exceptions = [@[ @"127.0.0.1", @"localhost", @"*.local",
                                       @"169.254.0.0/16", @"::1" ] mutableCopy];
      for (id entry in incoming) {
        if ([entry isKindOfClass:[NSString class]] &&
            ![exceptions containsObject:entry])
          [exceptions addObject:entry];
      }

      NSDictionary *proxies = @{
        @"HTTPEnable" : @1,
        @"HTTPProxy" : @"127.0.0.1",
        @"HTTPPort" : @(fwdPort),
        @"HTTPSEnable" : @1,
        @"HTTPSProxy" : @"127.0.0.1",
        @"HTTPSPort" : @(fwdPort),
        @"ProxyAutoDiscoveryEnable" : @0,
        @"ExceptionsList" : exceptions,
      };

      SCPreferencesRef prefs =
          SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
      if (!prefs) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"SCPreferencesCreate failed";
        return r;
      }
      BOOL ok = write_proxies(prefs, svc, proxies);
      CFRelease(prefs);
      if (!ok) {
        NSMutableDictionary *r = vp_make_response(@"err", reqId);
        r[@"msg"] = @"SCPreferences commit/apply failed";
        return r;
      }

      NSMutableDictionary *r = vp_make_response(@"proxy_set", reqId);
      r[@"ok"] = @YES;
      r[@"host"] = @"127.0.0.1";
      r[@"vsock"] = @YES;
      NSString *selfIP = first_ipv4_address();
      if (selfIP)
        r[@"guest_ip"] = selfIP;
      return r;
    }

    if (router.length == 0 || serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:
                       @"no global IPv4 route after setup on %@ (gateway=%@, static=%d); global=%@; interfaces: %@",
                       device ?: @"(no ethernet device)", gatewayUsed,
                       staticWritten,
                       global_ipv4() ?: @"(nil)", interface_summary()];
      return r;
    }

    NSArray *incoming = msg[@"exceptions"];
    NSMutableArray *exceptions = [@[ @"127.0.0.1", @"localhost", @"*.local",
                                     @"169.254.0.0/16", @"::1" ] mutableCopy];
    for (id entry in incoming) {
      if ([entry isKindOfClass:[NSString class]] &&
          ![exceptions containsObject:entry])
        [exceptions addObject:entry];
    }

    NSDictionary *proxies = @{
      @"HTTPEnable" : @1,
      @"HTTPProxy" : router,
      @"HTTPPort" : @(port),
      @"HTTPSEnable" : @1,
      @"HTTPSProxy" : router,
      @"HTTPSPort" : @(port),
      @"ProxyAutoDiscoveryEnable" : @0,
      @"ExceptionsList" : exceptions,
    };

    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    BOOL ok = write_proxies(prefs, serviceID, proxies);
    CFRelease(prefs);
    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferences commit/apply failed";
      return r;
    }

    NSMutableDictionary *r = vp_make_response(@"proxy_set", reqId);
    r[@"ok"] = @YES;
    r[@"host"] = router;
    NSString *selfIP = first_ipv4_address();
    if (selfIP)
      r[@"guest_ip"] = selfIP;
    return r;
  }

  // -- proxy_clear --
  if ([type isEqualToString:@"proxy_clear"]) {
    if (serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = [NSString stringWithFormat:@"no global IPv4 route; interfaces: %@",
                    interface_summary()];
      return r;
    }
    NSDictionary *proxies = @{
      @"HTTPEnable" : @0,
      @"HTTPSEnable" : @0,
      @"ProxyAutoDiscoveryEnable" : @0,
    };
    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    BOOL ok = write_proxies(prefs, serviceID, proxies);
    CFRelease(prefs);
    if (!ok) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferences commit/apply failed";
      return r;
    }
    NSMutableDictionary *r = vp_make_response(@"proxy_clear", reqId);
    r[@"ok"] = @YES;
    return r;
  }

  // -- proxy_get --
  if ([type isEqualToString:@"proxy_get"]) {
    if (serviceID.length == 0) {
      NSMutableDictionary *r = vp_make_response(@"proxy_get", reqId);
      r[@"enabled"] = @NO;
      return r;
    }
    SCPreferencesRef prefs =
        SCPreferencesCreate(NULL, CFSTR("vphoned"), NULL);
    if (!prefs) {
      NSMutableDictionary *r = vp_make_response(@"err", reqId);
      r[@"msg"] = @"SCPreferencesCreate failed";
      return r;
    }
    NSDictionary *proxies = read_proxies(prefs, serviceID);
    CFRelease(prefs);
    BOOL enabled = [proxies[@"HTTPEnable"] boolValue] ||
                   [proxies[@"HTTPSEnable"] boolValue];
    NSMutableDictionary *r = vp_make_response(@"proxy_get", reqId);
    r[@"enabled"] = @(enabled);
    r[@"host"] = proxies[@"HTTPProxy"];
    r[@"port"] = proxies[@"HTTPPort"];
    r[@"exceptions"] = proxies[@"ExceptionsList"] ?: @[];
    return r;
  }

  NSMutableDictionary *r = vp_make_response(@"err", reqId);
  r[@"msg"] = [NSString stringWithFormat:@"unknown proxy command: %@", type];
  return r;
}
