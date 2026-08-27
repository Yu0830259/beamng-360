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
      var hasLiveImage = false
      var lastState = 'starting'
      var lastAcceptedFrame = 0
      var pendingLoads = {}

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
          if (state === 'live' || state === 'ready' || state === 'frame') {
            debugPanel.classList.add('sv-debug--ok')
          } else {
            debugPanel.classList.remove('sv-debug--ok')
          }
        }
      }

      function loadBufferedFrame(frame, bufferIndex) {
        if (!rearImage || !bufferIndex || frame <= lastAcceptedFrame) return
        if (pendingLoads[frame]) return

        pendingLoads[frame] = true
        var file = bufferIndex === 2 ? 'rear_b.png' : 'rear_a.png'
        var src = 'local://local/screenshots/beamng-360/' + file + '?sv=' + frame + '-' + Date.now()
        var probe = new Image()

        probe.onload = function () {
          delete pendingLoads[frame]
          if (frame <= lastAcceptedFrame) return

          lastAcceptedFrame = frame
          rearImage.src = src
          if (rear) rear.classList.add('sv-camera--live')

          if (!hasLiveImage) {
            hasLiveImage = true
          }
          setStatus('live', 'REAR LIVE · frame ' + frame)
        }

        probe.onerror = function () {
          delete pendingLoads[frame]
          if (!hasLiveImage && lastState !== 'error') {
            setStatus('waiting', 'WAITING FOR BUFFER ' + bufferIndex + '…')
          }
        }

        // Small delay lets RenderView finish writing the PNG before Chromium
        // tries to decode it. The previous valid frame stays visible meanwhile.
        window.setTimeout(function () {
          probe.src = src
        }, 45)
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return

        if (data.state === 'frame' || data.state === 'ready') {
          loadBufferedFrame(Number(data.frame) || 0, Number(data.buffer) || 0)
          if (data.state === 'frame') return
        }

        setStatus(data.state, data.message || data.state)
      })

      setStatus('starting', 'STARTING DOUBLE-BUFFER RENDERVIEW…')

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
