local store = require('module')
function imported_run()
    store.persist()
end
function imported_shadow(store)
    store.persist()
end
