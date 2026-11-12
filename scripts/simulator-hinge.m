// Sets the hinge angle of a booted foldable simulator, such as iPhone Duo, from the Mac.
//
// simctl has no fold command, and Device Hub's pose buttons need a window and Accessibility
// access. This sends the message those buttons send: a vendor-defined HID event (usage page
// 0xFF61, usage 0x5B) over XPC to dtuhidd inside the simulator, which reports the angle to
// CoreMotion, so the system moves apps to the display the pose lights. It relies on private
// CoreSimulator and libxpc interfaces, so an Xcode update can break it; the screenshot script
// checks the display lights up instead of trusting the exit status alone.
//
// Usage: DEVELOPER_DIR=<Xcode>/Contents/Developer simulator-hinge <udid> <degrees>
//        0 is closed, 180 is open flat
// Build: xcrun clang -fobjc-arc -framework Foundation -o simulator-hinge simulator-hinge.m
//
// Adapted from tools/duo-hinge.m in duo-fold-control
// (https://github.com/tosbaha/duo-fold-control), under this license:
//
// MIT License
//
// Copyright (c) 2026 Mustafa Dur
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <math.h>
#import <objc/message.h>
#import <xpc/xpc.h>

static const char *const kService = "com.apple.coredevice.feature.remote.hid.vendordefined";
static const unsigned long long kSimDeviceStateBooted = 3;

extern xpc_endpoint_t xpc_endpoint_create_mach_port_4sim(mach_port_t port);
extern xpc_connection_t xpc_connection_create_from_endpoint(xpc_endpoint_t endpoint);
extern void xpc_connection_enable_sim2host_4sim(xpc_connection_t connection);

// The event's data is an IOKit binary serialization (OSSerializeBinary) of a dictionary.
typedef NS_ENUM(uint32_t, SerializedTag) {
  SerializedTagLast = 0x80000000,
  SerializedTagDictionary = 0x01000000,
  SerializedTagNumber = 0x04000000,
  SerializedTagSymbol = 0x08000000,
  SerializedTagString = 0x09000000,
};

static void appendWord(NSMutableData *data, uint32_t word) {
  [data appendBytes:&word length:sizeof(word)];
}

static void appendAligned(NSMutableData *data, const void *bytes, size_t length) {
  static const uint8_t padding[4] = {0, 0, 0, 0};
  [data appendBytes:bytes length:length];
  if (data.length % 4 != 0) {
    [data appendBytes:padding length:4 - data.length % 4];
  }
}

static void appendKey(NSMutableData *data, const char *key) {
  size_t length = strlen(key) + 1;
  appendWord(data, SerializedTagSymbol | (uint32_t)length);
  appendAligned(data, key, length);
}

static void appendString(NSMutableData *data, const char *value, BOOL last) {
  size_t length = strlen(value);
  appendWord(data, SerializedTagString | (uint32_t)length | (last ? SerializedTagLast : 0));
  appendAligned(data, value, length);
}

static void appendDouble(NSMutableData *data, double value, BOOL last) {
  // Device Hub marks its 64-bit angle with a width of 0x3f.
  appendWord(data, SerializedTagNumber | 0x3f | (last ? SerializedTagLast : 0));
  appendAligned(data, &value, sizeof(value));
}

static NSData *hingeEventData(double degrees) {
  NSMutableData *data = [NSMutableData data];
  appendWord(data, 0x000000d3);
  appendWord(data, SerializedTagDictionary | SerializedTagLast | 4);
  appendKey(data, "type");
  appendString(data, "range", NO);
  appendKey(data, "value");
  appendDouble(data, degrees, NO);
  appendKey(data, "source");
  appendString(data, "hinge-slider-control", NO);
  appendKey(data, "provider");
  appendString(data, "com.apple.Virtualization.VirtualMachines", YES);
  return data;
}

// Whether object answers selector; names the missing private interface when it doesn't.
static BOOL responds(id object, NSString *selector) {
  if ([object respondsToSelector:NSSelectorFromString(selector)]) {
    return YES;
  }
  NSString *owner = object == nil ? @"nil" : NSStringFromClass([object class]);
  fprintf(stderr, "CoreSimulator has no %s on %s; this Xcode changed its private interface\n",
          selector.UTF8String, owner.UTF8String);
  return NO;
}

static id bootedDevice(NSString *udid) {
  NSString *developerDirectory = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
  if (developerDirectory.length == 0) {
    fprintf(stderr, "Set DEVELOPER_DIR to the Xcode developer directory the simulator uses\n");
    return nil;
  }
  if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
              RTLD_NOW)) {
    fprintf(stderr, "Couldn't load CoreSimulator: %s\n", dlerror());
    return nil;
  }
  Class serviceContext = NSClassFromString(@"SimServiceContext");
  if (serviceContext == Nil) {
    fprintf(stderr, "CoreSimulator has no SimServiceContext class\n");
    return nil;
  }
  if (!responds(serviceContext, @"sharedServiceContextForDeveloperDir:error:")) {
    return nil;
  }
  NSError *error = nil;
  id context = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
    serviceContext, NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
    developerDirectory, &error);
  if (context == nil || !responds(context, @"defaultDeviceSetWithError:")) {
    fprintf(stderr, "Couldn't open CoreSimulator: %s\n", error.description.UTF8String);
    return nil;
  }
  id deviceSet = ((id(*)(id, SEL, NSError **))objc_msgSend)(
    context, NSSelectorFromString(@"defaultDeviceSetWithError:"), &error);
  if (deviceSet == nil) {
    fprintf(stderr, "Couldn't read the simulators: %s\n", error.description.UTF8String);
    return nil;
  }
  if (!responds(deviceSet, @"devices")) {
    return nil;
  }
  for (id device in ((id(*)(id, SEL))objc_msgSend)(deviceSet, NSSelectorFromString(@"devices"))) {
    if (!responds(device, @"UDID") || !responds(device, @"state")
        || !responds(device, @"lookup:error:")) {
      return nil;
    }
    if ([[[device valueForKey:@"UDID"] UUIDString] caseInsensitiveCompare:udid]
        != NSOrderedSame) {
      continue;
    }
    if ([[device valueForKey:@"state"] unsignedLongLongValue] != kSimDeviceStateBooted) {
      fprintf(stderr, "Simulator %s isn't booted\n", udid.UTF8String);
      return nil;
    }
    return device;
  }
  fprintf(stderr, "No simulator has the id %s\n", udid.UTF8String);
  return nil;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    char *end = NULL;
    double degrees = argc == 3 ? strtod(argv[2], &end) : NAN;
    if (argc != 3 || end == argv[2] || *end != '\0' || !isfinite(degrees) || degrees < 0
        || degrees > 180) {
      fprintf(stderr, "Usage: simulator-hinge <udid> <degrees from 0 to 180>\n");
      return 2;
    }
    id device = bootedDevice(@(argv[1]));
    if (device == nil) {
      return 1;
    }
    NSError *error = nil;
    mach_port_t port = ((mach_port_t(*)(id, SEL, NSString *, NSError **))objc_msgSend)(
      device, NSSelectorFromString(@"lookup:error:"), @(kService), &error);
    if (port == MACH_PORT_NULL) {
      fprintf(stderr, "Couldn't find the simulator's HID service: %s\n",
              error.description.UTF8String);
      return 1;
    }
    xpc_connection_t connection =
      xpc_connection_create_from_endpoint(xpc_endpoint_create_mach_port_4sim(port));
    xpc_connection_enable_sim2host_4sim(connection);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
      if (xpc_get_type(event) == XPC_TYPE_ERROR && event != XPC_ERROR_CONNECTION_INVALID) {
        fprintf(stderr, "XPC error: %s\n",
                xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
      }
    });
    xpc_connection_resume(connection);

    NSData *data = hingeEventData(degrees);
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usagePage", 0xFF61);
    xpc_dictionary_set_uint64(payload, "usage", 0x5B);
    xpc_dictionary_set_uint64(payload, "version", 0);
    xpc_dictionary_set_data(payload, "data", data.bytes, data.length);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", "IndigoVendorDefinedEvent");
    xpc_dictionary_set_string(message, "featureIdentifier", kService);
    xpc_dictionary_set_value(message, "payload", payload);
    xpc_connection_send_message(connection, message);

    // dtuhidd answers a barrier once it has handled everything sent before it.
    xpc_object_t barrier = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_bool(barrier, "isBarrier", true);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, barrier);
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
      fprintf(stderr, "The simulator didn't take the hinge angle: %s\n",
              xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION));
      return 1;
    }
    // Closing the connection removes its HID service, so give the system a moment to read the
    // event first.
    sleep(1);
  }
  return 0;
}
