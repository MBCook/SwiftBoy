//
//  SwiftBoyView.swift
//  Swift Boy
//
//  Created by Michael Cook on 12/3/22.
//

import SwiftUI

struct SwiftBoyView: View {
    @EnvironmentObject var swiftBoy: SwiftBoy
    
    var body: some View {
        VStack {
            swiftBoy.screen
                .antialiased(false)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: CGFloat(PIXELS_WIDE) * 3,
                       height: CGFloat(PIXELS_TALL) * 3)
                .fixedSize()
        }
        .scaledToFit()
    }
}

struct SwiftBoyView_Previews: PreviewProvider {
    static var previews: some View {
        SwiftBoyView()
    }
}
