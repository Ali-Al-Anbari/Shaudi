//
//  ContentView.swift
//  Shaudi
//
//  Created by Ali Al Anbari on 9/10/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "heart")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, Shaudi. YOU ARE VERY SEXYYY!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
