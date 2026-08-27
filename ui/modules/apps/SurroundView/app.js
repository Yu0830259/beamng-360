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
      var rearImageA = root.querySelector('#svRearImageA')
      var rearImageB = root.querySelector('#svRearImageB')
      var statusText = root.querySelector('#svCameraStatus')
      var debugPanel = root.querySelector('#svDebugPanel')
      var activeImage = rearImageA
      var standbyImage = rearImageB
      var hasLiveImage = false
      var lastState = 'starting'
      var lastAcceptedFrame = 0
      var loadingFrame = 0

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

      function swapDisplayedFrame(frame, bufferIndex) {
        if (!standbyImage || !bufferIndex || frame <= lastAcceptedFrame) return
        if (loadingFrame && frame <= loadingFrame) return

        loadingFrame = frame
        var file = bufferIndex === 2 ? 'rear_b.png' : 'rear_a.png'
        var src = 'local://local/screenshots/beamng-360/' + file + '?sv=' + frame + '-' + Date.now()
        var target = standbyImage

        target.onload = function () {
          if (frame < loadingFrame || frame <= lastAcceptedFrame) return

          lastAcceptedFrame = frame
          loadingFrame = 0

          // The previous image remains fully visible until this exact image
          // element has finished decoding. Only then do we atomically swap.
          target.classList.add('sv-live-image--active')
          if (activeImage) activeImage.classList.remove('sv-live-image--active')

          var oldActive = activeImage
          activeImage = target
          standbyImage = oldActive

          if (rear) rear.classList.add('sv-camera--live')
          hasLiveImage = true
          setStatus('live', 'REAR LIVE · frame ' + frame)
        }

        target.onerror = function () {
          if (frame === loadingFrame) loadingFrame = 0
          if (!hasLiveImage && lastState !== 'error') {
            setStatus('waiting', 'WAITING FOR COMPLETE FRAME…')
          }
        }

        // Never clear or modify the currently visible image here.
        // Only the hidden standby element receives the new source.
        window.setTimeout(function () {
          target.src = src
        }, 70)
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return

        if (data.state === 'frame' || data.state === 'ready') {
          swapDisplayedFrame(Number(data.frame) || 0, Number(data.buffer) || 0)
          if (data.state === 'frame') return
        }

        setStatus(data.state, data.message || data.state)
      })

      setStatus('starting', 'STARTING FLICKER-SAFE RENDERVIEW…')

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
        if (rearImageA) rearImageA.onload = rearImageA.onerror = null
        if (rearImageB) rearImageB.onload = rearImageB.onerror = null

        try {
          bngApi.engineLua("if extensions.surroundView and extensions.surroundView.stopRearCamera then pcall(extensions.surroundView.stopRearCamera) end")
        } catch (err) {
          console.error('SurroundView cleanup error', err)
        }
      })
    }
  }
}])
