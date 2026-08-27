angular.module('beamng.apps')
.directive('surroundView', [function () {
  return {
    templateUrl: '/ui/modules/apps/SurroundView/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      var root = element[0]
      var statusText = root.querySelector('#svCameraStatus')
      var debugPanel = root.querySelector('#svDebugPanel')

      function setStatus(state, message) {
        var text = message || state || 'UNKNOWN'
        if (statusText) {
          statusText.textContent = text
          statusText.setAttribute('data-state', state || '')
          statusText.title = text
        }
        if (debugPanel) {
          debugPanel.textContent = text
          debugPanel.setAttribute('data-state', state || '')
        }
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return
        setStatus(data.state, data.message || data.state)
      })

      setStatus('starting', 'STARTING GPU RENDERVIEW…')

      var startLua = [
        "local okLoad,loadErr=pcall(function() extensions.load('surroundView') end)",
        "if not okLoad then guihooks.trigger('SurroundViewStatus',{state='error',message='LOAD ERROR: '..tostring(loadErr)}) return end",
        "local ext=extensions.surroundView",
        "if not ext then guihooks.trigger('SurroundViewStatus',{state='error',message='EXTENSION NIL after load'}) return end",
        "local okStart,startErr=xpcall(function() return ext.startRearCamera() end,debug.traceback)",
        "if not okStart then guihooks.trigger('SurroundViewStatus',{state='error',message='START ERROR: '..tostring(startErr)}) end"
      ].join('; ')

      try {
        bngApi.engineLua(startLua)
      } catch (err) {
        setStatus('error', 'JS→LUA ERROR: ' + String(err))
      }

      scope.$on('$destroy', function () {
        try {
          bngApi.engineLua("if extensions.surroundView and extensions.surroundView.stopRearCamera then pcall(extensions.surroundView.stopRearCamera) end")
        } catch (err) {
          console.error('SurroundView cleanup error', err)
        }
      })
    }
  }
}])
