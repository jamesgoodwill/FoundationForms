//
//  ContentView.swift
//  FoundationForms
//
//  Created by James Goodwill on 5/8/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("AI") {
                    NavigationLink {
                        ChatView()
                    } label: {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationTitle("FoundationForms")
        }
    }
}

#Preview {
    ContentView()
}
