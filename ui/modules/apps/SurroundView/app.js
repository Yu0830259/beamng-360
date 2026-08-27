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
      var canvas = root.querySelector('#svRearCanvas')
      var ctx = canvas ? canvas.getContext('2d') : null
      var statusText = root.querySelector('#svCameraStatus')
      var debugPanel = root.querySelector('#svDebugPanel')

      for (var i = 0; i < views.length; i++) {
        views[i].classList.add('sv-camera--online')
      }

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

      function drawRgbFrame(frame) {
        if (!ctx || !frame || !frame.rgb) return

        try {
          var binary = atob(frame.rgb)
          var width = frame.width || 200
          var height = frame.height || 112
          var pixelCount = width * height

          if (binary.length < pixelCount * 3) {
            setStatus('error', 'FRAME SIZE ERROR: ' + binary.length)
            return
          }

          if (canvas.width !== width) canvas.width = width
          if (canvas.height !== height) canvas.height = height

          var image = ctx.createImageData(width, height)
          var dst = image.data
          var s = 0
          var d = 0

          for (var p = 0; p < pixelCount; p++) {
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = binary.charCodeAt(s++)
            dst[d++] = 255
          }

          ctx.putImageData(image, 0, 0)
          rear.classList.add('sv-camera--live')
          setStatus('live', 'REAR LIVE')
        } catch (err) {
          setStatus('error', 'FRAME DECODE ERROR: ' + String(err))
          console.error('SurroundView rear frame error', err)
        }
      }

      scope.$on('SurroundViewStatus', function (event, data) {
        if (!data) return
        setStatus(data.state, data.message || data.state)
      })

      scope.$on('SurroundViewRearFrame', function (event, data) {
        drawRgbFrame(data)
      })

      setStatus('starting', 'DIAG: calling Lua…')

      var startLua = [
        "guihooks.trigger('SurroundViewStatus',{state='diag',message='DIAG 1: Lua reached'})",
        "local okLoad,loadErr=pcall(function() extensions.load('surroundView') end)",
        "if not okLoad then guihooks.trigger('SurroundViewStatus',{state='error',message='LOAD ERROR: '..tostring(loadErr)}) return end",
        "guihooks.trigger('SurroundViewStatus',{state='diag',message='DIAG 2: extension load returned'})",
        "local ext=extensions.surroundView",
        "if not ext then guihooks.trigger('SurroundViewStatus',{state='error',message='EXTENSION NIL after load'}) return end",
        "if type(ext.startRearCamera)~='function' then guihooks.trigger('SurroundViewStatus',{state='error',message='startRearCamera missing'}) return end",
        "guihooks.trigger('SurroundViewStatus',{state='diag',message='DIAG 3: starting camera'})",
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
