import { mount } from 'svelte'
import App from './App.svelte'
import './app.css'
import { store } from './store.svelte'

// The Failed Extension prototype, so the first screen shows every kind of node.
store.source = `struct A {}

extension A {
  struct B {}
  typealias C = B
}

extension A.C {
  struct D {}
}

extension A.E {
  struct F {}
}
`

mount(App, { target: document.getElementById('app')! })
