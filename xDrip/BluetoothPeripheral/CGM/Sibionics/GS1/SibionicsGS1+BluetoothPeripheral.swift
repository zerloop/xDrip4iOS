//
//  SibionicsGS1+BluetoothPeripheral.swift
//  xdrip
//

import Foundation

extension SibionicsGS1: BluetoothPeripheral {

    func bluetoothPeripheralType() -> BluetoothPeripheralType {
        return .SibionicsGS1Type
    }

}
