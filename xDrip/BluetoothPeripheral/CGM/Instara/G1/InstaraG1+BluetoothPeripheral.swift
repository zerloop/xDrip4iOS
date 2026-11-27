//
//  InstaraG1+BluetoothPeripheral.swift
//  xdrip
//

import Foundation

extension InstaraG1: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        return .InstaraG1Type
    }

}
