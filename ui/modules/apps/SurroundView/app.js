angular.module('beamng.apps')
.directive('surroundView', [function () {
  return {
    templateUrl: '/ui/modules/apps/SurroundView/app.html',
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      var root = element[0]
      var views = root.querySelectorAll('.sv-camera')
      var rear = root.querySelector('.sv-rear')
      var rearImage = root.querySelector('#svRearImage')
      var statusText = root.querySelector('#svCameraStatus')
      var debugPanel = root.querySelector('#svDebugPanel')
      var refreshTimer = null
      var refreshSequence = 0
      var hasLiveImage = false
      var lastState = 'starting'

      for (var i = 0; i < views.length; i++) {
        views[i].classList.add('sv-camera--online')
      }

      function setStatus(state, message) {
        lastState = state || lastState
        var text = message || state || 'UNKNOWN'

        if (statusText) {
          statusText.textContent = text
          statusText.setAttribute('data-state', state || '')
          statusText.title = text
        }

        if (debugPanel) {
          debugPanel.textContent = text
          debugPanel.setAttribute('data-state', state || '')
          if (state === 'live' || state === 'ready') {
            debugPanel.classList.add('sv-debug--ok')
          } else {
            debugPanel.classList.remove('sv-debug--ok')
          }
        }
      }

      function reloadRearImage() {
        if (!rearImage) return

        refreshSequence++
        var src = 'local://local/screenshots/beamng-360/rear.png?sv=' + refreshSequence + '-' + Date.now()
        var probe = new Image()

        probe.onload = function () {
          rearImage.src = src
          if (rear) rear.classList.add('sv-camera--live')

          if (!hasLiveImage) {
            hasLiveImage = true
            setStatus('live', 'REAR RENDERVIEW LIVE')
          }
        }

        probe.onerror = function () {
          if (!hasLiveImage && lastState !== 'error') {
            setStatus('waiting', 'WAITING FOR RENDERVIEW FRAME…')
          }
        }

        probe.src = src
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return
        setStatus(data.state, data.message || data.state)
      })

      setStatus('starting', 'STARTING RETAIL RENDERVIEW…')

      var startLua = [
        "local okLoad,loadErr=pcall(function() extensions.load('surroundView') end)",
        "if not okLoad then guihooks.trigger('SurroundViewStatus',{state='error',message='LOAD ERROR: '..tostring(loadErr)}) return end",
        "local ext=extensions.surroundView",
        "if not ext then guihooks.trigger('SurroundViewStatus',{state='error',message='EXTENSION NIL after load'}) return end",
        "if type(ext.startRearCamera)~='function' then guihooks.trigger('SurroundViewStatus',{state='error',message='startRearCamera missing'}) return end",
        "local okStart,startErr=xpcall(function() return ext.startRearCamera() end,debug.traceback)",
        "if not okStart then guihooks.trigger('SurroundViewStatus',{state='error',message='START ERROR: '..tostring(startErr)}) end"
      ].join('; ')

      try {
        bngApi.engineLua(startLua)
      } catch (err) {
        setStatus('error', 'JS→LUA ERROR: ' + String(err))
      }

      // Retail BeamNG.drive RenderView writes the rear frame to the user
      // filesystem. Refresh at roughly 4 FPS; preload so a partial write does
      // not replace the last valid image.
      reloadRearImage()
      refreshTimer = window.setInterval(reloadRearImage, 250)

      scope.$on('$destroy', function () {
        if (refreshTimer !== null) {
          window.clearInterval(refreshTimer)
          refreshTimer = null
        }

        try {
          bngApi.engineLua("if extensions.surroundView and extensions.surroundView.stopRearCamera then pcall(extensions.surroundView.stopRearCamera) end")
        } catch (err) {
          console.error('SurroundView cleanup error', err)
        }
      })
    }
  }
}])
