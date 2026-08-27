/*
 * vphoned_proxy — System-wide HTTP proxy configuration via SCPreferences.
 */

#pragma once
#import <Foundation/Foundation.h>

/// Handle proxy_* commands: proxy_set / proxy_clear / proxy_get.
NSDictionary *vp_handle_proxy_command(NSDictionary *msg);
