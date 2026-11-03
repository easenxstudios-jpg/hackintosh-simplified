// Asks macOS to open a Bluetooth connection to one device and reports the result.
ObjC.import('IOBluetooth');
function run(argv) {
  var dev = $.IOBluetoothDevice.deviceWithAddressString(argv[0]);
  if (!dev || dev.isNil()) return 'device not found';
  var t0 = $.NSDate.date;
  var r = dev.openConnection;
  var secs = -t0.timeIntervalSinceNow;
  return 'openConnection result=' + r + ' after ' + secs.toFixed(1) + ' s, isConnected=' + dev.isConnected;
}
