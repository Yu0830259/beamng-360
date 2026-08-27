angular.module('beamng.apps')
.directive('surroundView', [function () {
  return {
    templateUrl: '/ui/modules/apps/SurroundView/app.html',
    replace: true,
    restrict: 'E',
    link: function (scope, element) {
      const root = element[0]

      // Prototype state. Later these panels can be connected to
      // BeamNG camera/sensor render targets through Lua/engine hooks.
      const views = root.querySelectorAll('.sv-camera')
      views.forEach((view) => {
        view.classList.add('sv-camera--online')
      })

      scope.$on('$destroy', function () {
        // Reserved for camera cleanup once live render targets are added.
      })
    }
  }
}])
