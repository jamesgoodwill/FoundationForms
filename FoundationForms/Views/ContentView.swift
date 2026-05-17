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
                Section("Forms") {
                    NavigationLink {
                        PatientIntakeView()
                    } label: {
                        Label("Patient Intake", systemImage: "list.bullet.clipboard")
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
