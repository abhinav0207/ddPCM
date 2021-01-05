!> @copyright (c) 2020-2020 RWTH Aachen. All rights reserved.
!!
!! ddX software
!!
!! @file src/dd_cosmo.f90
!! COSMO model in the domain decomposition framework
!!
!! @version 1.0.0
!! @author Aleksandr Mikhalev
!! @date 2020-12-17

!> Core routines and parameters of ddX software
module dd_cosmo
use dd_core
use dd_operators
use dd_solvers
implicit none

contains

subroutine ddcosmo(dd_data, phi, psi, tol, ndiis, niter)
    ! Inputs:
    type(dd_data_type), intent(in)  :: dd_data
    real(kind=rp), intent(in) :: phi(dd_data % ncav), &
        & psi(dd_data % nbasis, dd_data % nsph)
    real(kind=rp), intent(in) :: tol
    integer, intent(in) :: ndiis
    integer, intent(inout) :: niter
    ! Local variables
    real(kind=rp), allocatable :: g(:, :), rhs(:, :), xs(:, :)
    integer :: istatus, isph
    logical :: ok
    ! Accumulate right hand side
    allocate(g(dd_data % ngrid, dd_data % nsph), &
        & rhs(dd_data % nbasis, dd_data % nsph), stat=istatus)
    call wghpot(dd_data, phi, g)
    do isph = 1, dd_data % nsph
        call intrhs(dd_data % iprint, dd_data % ngrid, dd_data % lmax, &
            & dd_data % vwgrid, isph, g(:, isph), rhs(:, isph))
    end do
    allocate(xs(dd_data % nbasis, dd_data % nsph))
    xs = zero
    call jacobi_diis(dd_data, dd_data % n, dd_data % iprint, ndiis, 4, tol, &
        & rhs, xs, niter, ok, lx, ldm1x, hnorm)
    call prtsph('x', dd_data % nbasis, dd_data % lmax, dd_data % nsph, 0, xs)
    deallocate(xs)
    deallocate(g, rhs)
end subroutine ddcosmo

end module dd_cosmo
